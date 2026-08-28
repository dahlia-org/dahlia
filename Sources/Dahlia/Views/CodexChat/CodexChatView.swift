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
    let contentMaxWidth: CGFloat?

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

            VStack(spacing: 0) {
                if showsHistory {
                    CodexChatHistoryView(
                        threads: coordinator.history,
                        meetingNamesByID: session.meetingNamesByID,
                        hasMore: coordinator.historyCursor != nil,
                        isLoading: coordinator.isLoadingHistory,
                        activityForThread: coordinator.activity(for:),
                        onNewChat: startNewChat,
                        onOpenThread: openHistoryThread,
                        onLoadMore: loadMoreHistory
                    )
                } else if showsEmptyState {
                    CodexChatEmptyStateView(
                        recentThreads: Array(coordinator.history.prefix(3)),
                        meetingNamesByID: session.meetingNamesByID,
                        showsProjectOrganizationShortcut: session.showsProjectOrganizationShortcut,
                        isProjectOrganizationShortcutEnabled: session.canSendProjectOrganizationShortcut,
                        onOrganizeRecentMeetingsAndProjects: { session.sendProjectOrganizationShortcut() },
                        meetingReviewShortcutTitle: session.showsMeetingReviewShortcut
                            ? CodexChatMeetingReviewShortcut.title
                            : nil,
                        isMeetingReviewShortcutEnabled: session.canSendMeetingReviewShortcut,
                        activityForThread: coordinator.activity(for:),
                        onReviewMeeting: session.sendMeetingReviewShortcut,
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
                } else if let historyError = coordinator.historyError, showsHistory || showsEmptyState {
                    CodexChatErrorView(
                        message: historyError,
                        onRetry: retryHistory
                    )
                }

                if !showsHistory {
                    conversationControls
                }
            }
            .frame(maxWidth: contentMaxWidth ?? .infinity)
            .frame(maxWidth: .infinity)
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
        .onChange(of: session.didStartBackendThread) { _, didStartBackendThread in
            guard showsHistory, didStartBackendThread else { return }
            Task { await coordinator.refreshHistory() }
        }
    }

    @ViewBuilder
    private var conversationControls: some View {
        if let noticeMessage = session.noticeMessage {
            Label(noticeMessage, systemImage: "info.circle.fill")
                .font(.body)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
                .padding(.vertical, 6)
        }

        if let request = session.pendingUserInput {
            CodexChatUserInputView(
                request: request,
                isEnabled: session.respondingUserInputID == nil,
                onSubmit: { answer in
                    session.respondToUserInput(id: request.id, answer: answer)
                },
                onStop: session.stop
            )
            .padding(.horizontal, CodexChatDesign.composerHorizontalPadding)
            .padding(.bottom, CodexChatDesign.composerBottomPadding)
        } else if let pendingApproval = session.pendingApproval {
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

    private var showsEmptyState: Bool {
        session.messages.isEmpty && !session.showsStandaloneThinking
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
