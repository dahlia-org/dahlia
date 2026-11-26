import SwiftUI

/// Chat history rows for the Chat sidebar's `List`.
struct MainSidebarChatHistorySection: View {
    var coordinator: CodexChatCoordinator
    var sidebarViewModel: SidebarViewModel
    /// Whether the main area shows the chat, so the open thread's row is the selected item.
    let isShowingChat: Bool
    @Binding var selection: MainSidebarChatSelection
    let onNewChat: () -> Void
    let onOpenThread: (CodexChatThreadSummary) -> Void

    @State private var isExpanded = true

    var body: some View {
        MeetingSidebarHeader(
            title: L10n.chat,
            isExpanded: isExpanded,
            onToggleExpansion: { isExpanded.toggle() },
            addButtonTitle: L10n.newChat,
            onAdd: onNewChat,
            count: coordinator.activeCount
        )
        .listRowSeparator(.hidden)
        // Keyed on the docked session: an account change replaces it and clears history without a refresh while docked chat is hidden.
        .task(id: coordinator.dockedSessionID) {
            sidebarViewModel.loadMeetingReferencesIfNeeded()
            syncMeetingCatalog()
            if coordinator.history.isEmpty || coordinator.isHistoryStale {
                await coordinator.refreshHistory()
            }
        }
        // Titles name meetings through the docked session's catalog, which only a mounted chat view fills otherwise.
        .onChange(of: sidebarViewModel.meetingReferences) { syncMeetingCatalog() }
        .onChange(of: sidebarViewModel.isMeetingCatalogLoaded) { syncMeetingCatalog() }
        // The coordinator marks history stale, without refreshing, when the current chat's new thread becomes listable.
        .onChange(of: coordinator.isHistoryStale) { _, isStale in
            guard isStale else { return }
            Task { await coordinator.refreshHistory() }
        }

        if isExpanded {
            MainSidebarChatThreadRows(
                coordinator: coordinator,
                threads: CodexChatThreadSummary.sidebarThreads(coordinator.history),
                isShowingChat: isShowingChat,
                isSettled: false,
                selection: $selection,
                onOpenThread: onOpenThread
            )

            statusRow
                .listRowInsets(.vertical, 1.5)
                .listRowSeparator(.hidden)
        }
    }

    private func syncMeetingCatalog() {
        coordinator.dockedSession.updateAvailableMeetings(
            sidebarViewModel.meetingReferences,
            catalogWorkspaceID: sidebarViewModel.currentWorkspace?.id,
            isCatalogLoaded: sidebarViewModel.isMeetingCatalogLoaded
        )
    }

    @ViewBuilder
    private var statusRow: some View {
        if coordinator.isLoadingHistory {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = coordinator.historyError {
            VStack(alignment: .leading, spacing: 4) {
                Text(error)
                    .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
                Button(L10n.retry) { Task { await coordinator.refreshHistory() } }
            }
        } else if CodexChatThreadSummary.sidebarThreads(coordinator.history).isEmpty, coordinator.historyCursor == nil {
            Text(L10n.noRecentChats)
                .foregroundStyle(DahliaDesign.sidebarSecondaryTextColor)
        } else if coordinator.historyCursor != nil {
            Button {
                Task { await coordinator.loadMoreHistory() }
            } label: {
                MainSidebarNavigationLabel(title: L10n.loadMore, systemImage: "ellipsis")
                    .font(.dahliaBody)
            }
            .buttonStyle(.plain)
        }
    }
}

/// As T3 Code's Settled shelf: a section of its own, at the same level as Chat. Collapsed, its header stays against the
/// sidebar's footer; expanded, the section joins the end of the sidebar's list, which scrolls as a whole. It shows its
/// count either way and lists 25 threads at a time.
struct MainSidebarSettledSection: View {
    var coordinator: CodexChatCoordinator
    let isShowingChat: Bool
    @Binding var isExpanded: Bool
    @Binding var selection: MainSidebarChatSelection
    let onOpenThread: (CodexChatThreadSummary) -> Void

    var body: some View {
        if coordinator.settledCount > 0 {
            MeetingSidebarHeader(
                title: L10n.chatSettledSection,
                isExpanded: isExpanded,
                onToggleExpansion: { isExpanded.toggle() },
                count: coordinator.settledCount,
                showsCountWhenExpanded: true
            )
            .listRowSeparator(.hidden)
            if isExpanded {
                MainSidebarChatThreadRows(
                    coordinator: coordinator,
                    threads: CodexChatThreadSummary.sidebarThreads(coordinator.settledHistory),
                    isShowingChat: isShowingChat,
                    isSettled: true,
                    selection: $selection,
                    onOpenThread: onOpenThread
                )
                let remaining = coordinator.settledCount - CodexChatThreadSummary.sidebarThreads(coordinator.settledHistory).count
                if coordinator.settledCursor != nil, remaining > 0 {
                    Button { Task { await coordinator.loadMoreSettled() } } label: {
                        MainSidebarNavigationLabel(title: L10n.chatShowMore(min(remaining, 25)), systemImage: "chevron.down")
                            .font(.dahliaBody)
                    }
                    .buttonStyle(.plain)
                    .disabled(coordinator.isLoadingSettled)
                    .listRowInsets(.vertical, 1.5)
                    .listRowSeparator(.hidden)
                }
            }
        }
    }
}

/// Finder-style selection of chat rows. Command-click toggles a row and Shift-click selects the range from the last
/// clicked row, within one section at a time; a plain click clears it and opens the thread.
struct MainSidebarChatSelection: Equatable {
    private(set) var ids: Set<String> = []
    private(set) var isSelecting = false
    private var anchorID: String?

    /// Returns whether the click only changed the selection, so the thread should not open.
    mutating func click(_ id: String, modifiers: NSEvent.ModifierFlags, order: [String], openID: String?) -> Bool {
        let openID = openID.flatMap { order.contains($0) ? $0 : nil }
        // A selection in the other section does not carry over.
        if let anchorID, !order.contains(anchorID) { clear() }
        ids.formIntersection(order)

        if modifiers.contains(.shift) {
            isSelecting = true
            let anchor = anchorID ?? openID ?? id
            if let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
                ids = Set(order[min(from, to) ... max(from, to)])
            }
            anchorID = anchor
            return true
        }
        if modifiers.contains(.command) {
            if !isSelecting, let openID { ids = [openID] }
            isSelecting = true
            if ids.remove(id) == nil { ids.insert(id) }
            anchorID = id
            return true
        }
        clear()
        anchorID = id
        return false
    }

    /// The threads an action on `thread` applies to: the selection when it includes the thread, otherwise the thread alone.
    func targets(for thread: CodexChatThreadSummary, in threads: [CodexChatThreadSummary]) -> [CodexChatThreadSummary] {
        ids.contains(thread.id) ? threads.filter { ids.contains($0.id) } : [thread]
    }

    mutating func clear() {
        ids = []
        isSelecting = false
        anchorID = nil
    }
}

/// One section's thread rows, sharing the sidebar's chat selection.
private struct MainSidebarChatThreadRows: View {
    var coordinator: CodexChatCoordinator
    let threads: [CodexChatThreadSummary]
    let isShowingChat: Bool
    let isSettled: Bool
    @Binding var selection: MainSidebarChatSelection
    let onOpenThread: (CodexChatThreadSummary) -> Void

    private var openID: String? { isShowingChat ? coordinator.dockedSession.backendThreadID : nil }

    var body: some View {
        ForEach(threads) { thread in
            MainSidebarChatThreadRow(
                coordinator: coordinator,
                thread: thread,
                isSelected: selection.isSelecting ? selection.ids.contains(thread.id) : thread.id == openID,
                isSettled: isSettled,
                actionCount: actionTargets(for: thread).count,
                onOpen: { open(thread) },
                onToggleSettled: { toggleSettled(thread) }
            )
            .listRowInsets(.vertical, 1.5)
            .listRowSeparator(.hidden)
        }
    }

    private func open(_ thread: CodexChatThreadSummary) {
        let order = threads.map(\.id)
        if !selection.click(thread.id, modifiers: NSEvent.modifierFlags, order: order, openID: openID) {
            onOpenThread(thread)
        }
    }

    /// Work in progress is not settled from here; its status stays in view.
    private func actionTargets(for thread: CodexChatThreadSummary) -> [CodexChatThreadSummary] {
        selection.targets(for: thread, in: threads).filter { coordinator.activity(for: $0.id) == nil }
    }

    private func toggleSettled(_ thread: CodexChatThreadSummary) {
        let targets = actionTargets(for: thread)
        guard !targets.isEmpty else { return }
        selection.clear()
        Task { await coordinator.setSettled(targets, !isSettled) }
    }
}

/// A thread's row. On hover, a button settles it (or, in the Settled section, brings it back) in place of its status;
/// on a selected row, the button and the context menu act on the whole selection.
private struct MainSidebarChatThreadRow: View {
    var coordinator: CodexChatCoordinator
    let thread: CodexChatThreadSummary
    let isSelected: Bool
    let isSettled: Bool
    /// How many threads the settle action covers; 0 when the thread has work in progress.
    let actionCount: Int
    let onOpen: () -> Void
    let onToggleSettled: () -> Void

    @State private var isHovered = false

    private var title: String {
        CodexChatMeetingReference.displayText(
            for: thread.title.nilIfBlank ?? L10n.newChat,
            namesByID: coordinator.dockedSession.meetingNamesByID
        )
    }

    private var activity: CodexChatThreadActivity? { coordinator.activity(for: thread.id) }
    private var showsSettleButton: Bool { isHovered && activity == nil }

    private var settleLabel: String {
        if actionCount > 1 {
            return isSettled ? L10n.chatUnsettleThreads(actionCount) : L10n.chatSettleThreads(actionCount)
        }
        return isSettled ? L10n.chatUnsettleThread : L10n.chatSettleThread
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Text(title)
                    .lineLimit(1)

                Spacer(minLength: 8)

                // Hidden, not removed, so the title does not move when the button shows.
                CodexChatThreadStatusView(thread: thread, activity: activity)
                    .opacity(showsSettleButton ? 0 : 1)
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(.rect)
            .modifier(SidebarNavigationRowModifier(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if showsSettleButton {
                CodexChatIconButton(
                    label: settleLabel,
                    systemImage: isSettled ? "arrow.uturn.backward" : "checkmark",
                    size: 22,
                    action: onToggleSettled
                )
                .padding(.trailing, 4)
            }
        }
        .onHover { isHovered = $0 }
        // A row that appears or slides under a still pointer gets no hover event; settling the top row does both.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            isHovered = Self.pointerIsInside(frame)
        }
        .contextMenu {
            if actionCount > 0 {
                Button(settleLabel, action: onToggleSettled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions {
            if actionCount > 0 {
                Button(settleLabel, action: onToggleSettled)
            }
        }
    }

    private static func pointerIsInside(_ frame: CGRect) -> Bool {
        guard let window = NSApp.keyWindow, let contentView = window.contentView else { return false }
        let point = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return frame.contains(CGPoint(x: point.x, y: contentView.isFlipped ? point.y : contentView.bounds.height - point.y))
    }
}
