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
            addButtonSystemImage: "plus.message",
            onAdd: onNewChat
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
            ForEach(CodexChatThreadSummary.sidebarThreads(coordinator.history)) { thread in
                Button { onOpenThread(thread) } label: {
                    MainSidebarChatThreadRow(
                        title: CodexChatMeetingReference.displayText(
                            for: thread.title.nilIfBlank ?? L10n.newChat,
                            namesByID: coordinator.dockedSession.meetingNamesByID
                        ),
                        thread: thread,
                        activity: coordinator.activity(for: thread.id),
                        isSelected: isShowingChat && thread.id == coordinator.dockedSession.backendThreadID
                    )
                }
                .buttonStyle(.plain)
                .listRowInsets(.vertical, 1.5)
                .listRowSeparator(.hidden)
            }

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

private struct MainSidebarChatThreadRow: View {
    let title: String
    let thread: CodexChatThreadSummary
    let activity: CodexChatThreadActivity?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)

            Spacer(minLength: 8)

            CodexChatThreadStatusView(thread: thread, activity: activity)
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(.rect)
        .modifier(SidebarNavigationRowModifier(isSelected: isSelected))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
