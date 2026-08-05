import SwiftUI

struct CodexChatView: View {
    @Bindable var session: CodexChatSessionModel
    @Bindable var coordinator: CodexChatCoordinator
    let meetingReferences: [CodexChatMeetingReference]
    let meetingCatalogVaultID: UUID?
    let isMeetingCatalogLoaded: Bool
    let allowsPopOut: Bool
    let onNewChat: () -> Void
    let onPopOut: () -> Void
    let onHide: (() -> Void)?
    let onOpenHistory: (CodexChatThreadSummary) -> Void
    var onHeaderDragChanged: ((CGSize) -> Void)?
    var onHeaderDragEnded: ((CGSize) -> Void)?
    @State private var showsHistory = false

    var body: some View {
        VStack(spacing: 0) {
            CodexChatHeader(
                title: session.displayTitle,
                showsHistory: showsHistory,
                hasConversation: !session.messages.isEmpty,
                allowsPopOut: allowsPopOut,
                onBack: hideHistory,
                onShowHistory: showHistory,
                onNewChat: startNewChat,
                onPopOut: onPopOut,
                onHide: onHide,
                onDragChanged: onHeaderDragChanged,
                onDragEnded: onHeaderDragEnded
            )

            if showsHistory {
                CodexChatHistoryView(
                    threads: coordinator.history,
                    meetingNamesByID: session.meetingNamesByID,
                    hasMore: coordinator.historyCursor != nil,
                    isLoading: coordinator.isLoadingHistory,
                    onNewChat: startNewChat,
                    onOpenThread: openHistoryThread,
                    onLoadMore: loadMoreHistory
                )
            } else if session.messages.isEmpty, !session.showsStandaloneThinking {
                CodexChatEmptyStateView(
                    recentThreads: Array(coordinator.history.prefix(3)),
                    meetingNamesByID: session.meetingNamesByID,
                    showsProjectOrganizationShortcut: session.showsProjectOrganizationShortcut,
                    isProjectOrganizationShortcutEnabled: session.canSendProjectOrganizationShortcut,
                    onOrganizeRecentMeetingsAndProjects: { session.sendProjectOrganizationShortcut() },
                    onOpenThread: openHistoryThread,
                    onShowAll: showHistory
                )
            } else {
                CodexChatConversationView(
                    messages: session.messages,
                    showsStandaloneThinking: session.showsStandaloneThinking,
                    meetingNamesByID: session.meetingNamesByID,
                    meetingReferencesByID: session.meetingReferencesByID
                )
            }

            if let errorMessage = session.errorMessage {
                CodexChatErrorView(
                    message: errorMessage,
                    onRetry: session.hasRetryableSubmission ? session.retry : retryConnection
                )
            } else if let historyError = coordinator.historyError {
                CodexChatErrorView(
                    message: historyError,
                    onRetry: retryHistory
                )
            }

            if let noticeMessage = session.noticeMessage {
                Label(noticeMessage, systemImage: "info.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
                    .padding(.vertical, 6)
            }

            if let pendingApproval = session.pendingApproval {
                CodexChatApprovalView(
                    request: pendingApproval,
                    isDecisionEnabled: session.canDecidePendingApproval,
                    onDecide: session.respondToApproval
                )
                .padding(.horizontal, CodexChatDesign.composerHorizontalPadding)
                .padding(.bottom, CodexChatDesign.composerBottomPadding)
            } else {
                CodexChatLiveModeStatusView(
                    isEnabled: $session.liveModeEnabled,
                    isAvailable: session.isBoundToCurrentVault
                )
                .padding(.horizontal, CodexChatDesign.composerHorizontalPadding)
                .padding(.bottom, CodexChatDesign.liveModeStatusBottomPadding)

                CodexChatComposer(session: session)
                    .padding(.horizontal, CodexChatDesign.composerHorizontalPadding)
                    .padding(.bottom, CodexChatDesign.composerBottomPadding)
            }
        }
        .background(.background)
        .task(id: session.id) { await prepare() }
        .onChange(of: meetingReferences) {
            updateMeetingCatalog()
        }
        .onChange(of: meetingCatalogVaultID) {
            updateMeetingCatalog()
        }
        .onChange(of: isMeetingCatalogLoaded) {
            updateMeetingCatalog()
        }
    }

    private func prepare() async {
        updateMeetingCatalog()
        await session.restore()
        if coordinator.history.isEmpty {
            await coordinator.refreshHistory()
        }
    }

    private func updateMeetingCatalog() {
        session.updateAvailableMeetings(
            meetingReferences,
            catalogVaultID: meetingCatalogVaultID,
            isCatalogLoaded: isMeetingCatalogLoaded
        )
    }

    private func showHistory() {
        showsHistory = true
        Task { await coordinator.refreshHistory() }
    }

    private func hideHistory() {
        showsHistory = false
    }

    private func startNewChat() {
        showsHistory = false
        onNewChat()
    }

    private func openHistoryThread(_ thread: CodexChatThreadSummary) {
        showsHistory = false
        onOpenHistory(thread)
    }

    private func loadMoreHistory() {
        Task { await coordinator.loadMoreHistory() }
    }

    private func retryConnection() {
        Task { await session.prepare(forceRefresh: true) }
    }

    private func retryHistory() {
        Task { await coordinator.refreshHistory() }
    }
}
