import SwiftUI

/// Chat history rows for the Chat sidebar's `List`.
struct MainSidebarChatHistorySection: View {
    var coordinator: CodexChatCoordinator
    var sidebarViewModel: SidebarViewModel
    /// Whether the main area shows the chat, so the open thread's row is the selected item.
    let isShowingChat: Bool
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
            ForEach(CodexChatThreadSummary.sidebarThreads(coordinator.history)) { thread in row(thread, isSettled: false) }

            statusRow
                .listRowInsets(.vertical, 1.5)
                .listRowSeparator(.hidden)
        }
    }

    private func row(_ thread: CodexChatThreadSummary, isSettled: Bool) -> some View {
        MainSidebarChatThreadRow(coordinator: coordinator, thread: thread, isShowingChat: isShowingChat, isSettled: isSettled) {
            onOpenThread(thread)
        }
        .listRowInsets(.vertical, 1.5)
        .listRowSeparator(.hidden)
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
                ForEach(CodexChatThreadSummary.sidebarThreads(coordinator.settledHistory)) { thread in
                    MainSidebarChatThreadRow(coordinator: coordinator, thread: thread, isShowingChat: isShowingChat, isSettled: true) {
                        onOpenThread(thread)
                    }
                    .listRowInsets(.vertical, 1.5)
                    .listRowSeparator(.hidden)
                }
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

/// A thread's row. On hover, a button settles it (or, in the Settled section, brings it back) in place of its status.
private struct MainSidebarChatThreadRow: View {
    var coordinator: CodexChatCoordinator
    let thread: CodexChatThreadSummary
    let isShowingChat: Bool
    let isSettled: Bool
    let onOpen: () -> Void

    @State private var isHovered = false

    private var title: String {
        CodexChatMeetingReference.displayText(
            for: thread.title.nilIfBlank ?? L10n.newChat,
            namesByID: coordinator.dockedSession.meetingNamesByID
        )
    }

    private var activity: CodexChatThreadActivity? { coordinator.activity(for: thread.id) }
    private var isSelected: Bool { isShowingChat && thread.id == coordinator.dockedSession.backendThreadID }
    /// Work in progress is not settled from here; its status stays in view.
    private var showsSettleButton: Bool { isHovered && activity == nil }

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
                    label: isSettled ? L10n.chatUnsettleThread : L10n.chatSettleThread,
                    systemImage: isSettled ? "arrow.uturn.backward" : "checkmark",
                    size: 22,
                    action: toggleSettled
                )
                .padding(.trailing, 4)
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions {
            if activity == nil {
                Button(isSettled ? L10n.chatUnsettleThread : L10n.chatSettleThread, action: toggleSettled)
            }
        }
    }

    private func toggleSettled() {
        Task { await coordinator.setSettled(thread, !isSettled) }
    }
}
