import SwiftUI

struct CodexChatView: View {
    @Bindable var session: CodexChatSessionModel
    @Bindable var coordinator: CodexChatCoordinator
    let meetingReferences: [CodexChatMeetingReference]
    let meetingCatalogVaultID: UUID?
    let isMeetingCatalogLoaded: Bool
    @Binding var showsHistory: Bool
    var configurationPresentation: Binding<Bool>?
    let onNewChat: () -> Void
    let onOpenHistory: (CodexChatThreadSummary) -> Void
    let onShowFullScreen: (() -> Void)?
    let onPopOut: (() -> Void)?
    let reservesSidebarToggle: Bool
    let reservesWindowControls: Bool

    var body: some View {
        VStack(spacing: 0) {
            CodexChatHeader(
                title: session.displayTitle,
                showsHistory: showsHistory,
                hasConversation: !session.messages.isEmpty,
                onBack: hideHistory,
                onShowHistory: showHistory,
                onNewChat: startNewChat,
                onShowFullScreen: onShowFullScreen,
                onPopOut: onPopOut,
                reservesSidebarToggle: reservesSidebarToggle,
                reservesWindowControls: reservesWindowControls
            )
            .zIndex(1)

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
                    .font(.body)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
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
                if session.liveModeEnabled {
                    CodexChatLiveModeStatusView(
                        isShortcutEnabled: session.canSendLiveModeShortcut,
                        onDisable: session.disableLiveMode,
                        onSubmit: session.sendLiveModeShortcut
                    )
                    .padding(.horizontal, CodexChatDesign.liveModeStatusOuterHorizontalPadding)
                    .padding(.bottom, CodexChatDesign.liveModeStatusBottomPadding)
                }

                CodexChatComposer(
                    session: session,
                    configurationPresentation: configurationPresentation
                )
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
        Task { await session.restore() }
    }

    private func retryHistory() {
        Task { await coordinator.refreshHistory() }
    }
}
