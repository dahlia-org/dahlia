import SwiftUI

struct CodexChatView: View {
    @Bindable var session: CodexChatSessionModel
    @Bindable var coordinator: CodexChatCoordinator
    let meetingReferences: [CodexChatMeetingReference]
    let meetingCatalogWorkspaceID: UUID?
    let isMeetingCatalogLoaded: Bool
    @Binding var showsHistory: Bool
    var configurationPresentation: Binding<Bool>?
    let onNewChat: () -> Void
    let onOpenHistory: (CodexChatThreadSummary) -> Void
    let onShowFullScreen: (() -> Void)?
    let onPopOut: (() -> Void)?
    let reservesSidebarToggle: Bool
    let reservesWindowControls: Bool
    let headerLeadingInset: CGFloat
    let contentMaxWidth: CGFloat?
    /// The side panel leaves out the title and keeps a new chat's composer at the bottom, as in a conversation. Elsewhere a
    /// new chat centers its composer under a welcome.
    var isSidePanel = false

    @Environment(MainWindowNavigation.self) private var navigation
    @State private var dismissedIntegrationsSessionID: CodexChatSessionID?

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
                reservesWindowControls: reservesWindowControls,
                leadingInset: headerLeadingInset,
                showsTitle: !isSidePanel
            )
            .zIndex(1)

            GeometryReader { geometry in
                VStack(spacing: 0) {
                    if showsWelcome {
                        Spacer(minLength: 12)
                    }

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
                    } else if showsWelcome {
                        CodexChatWelcomeHeader(showsIcon: geometry.size.height >= 480)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 24)
                    } else if showsEmptyState {
                        // The side panel lists the shortcuts and recent chats above its bottom composer.
                        Spacer(minLength: 12)
                        emptyState
                            .frame(maxHeight: geometry.size.height * 0.4)
                            .padding(.bottom, 12)
                    } else {
                        CodexChatConversationView(
                            conversationID: session.id,
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
                        // Keep one composer in the view tree, preserving focus and attachments when the first message is sent.
                        conversationControls
                    }

                    if showsWelcome {
                        if dismissedIntegrationsSessionID != session.id {
                            CodexChatAppIntegrationsView(
                                onOpenSettings: { navigation.openAgentSettings(tab: .mcps) },
                                onDismiss: { dismissedIntegrationsSessionID = session.id }
                            )
                            .padding(.horizontal, CodexChatDesign.composerHorizontalPadding)
                            .padding(.bottom, 18)
                        }

                        emptyState
                            .frame(maxHeight: geometry.size.height * 0.28)

                        Spacer(minLength: 12)
                    }
                }
                .frame(maxWidth: showsWelcome ? 720 : (contentMaxWidth ?? .infinity))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(name: CodexChatAddPanelLayout.coordinateSpaceName)
        }
        .background(.background)
        .task(id: session.id) { await prepare() }
        .onReceive(NotificationCenter.default.publisher(for: PiRuntimeService.modelsDidChange).receive(on: RunLoop.main)) { _ in
            Task { await session.prepare(forceRefresh: true) }
        }
        .onChange(of: meetingReferences) {
            updateMeetingCatalog()
        }
        .onChange(of: meetingCatalogWorkspaceID) {
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
        if let command = session.pendingCommand {
            HStack {
                Label(L10n.chatCommandQueued(command.text), systemImage: "clock")
                    .lineLimit(1)
                    .help(command.text)
                Spacer(minLength: 8)
                Button(L10n.cancel) { session.cancelPendingCommand(command) }
                    .buttonStyle(.borderless)
            }
            .font(.dahliaBody)
            .foregroundStyle(DahliaDesign.secondaryTextColor)
            .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
            .padding(.vertical, 6)
        }

        if let activity = session.toolActivity {
            Label(activity.text, systemImage: activity.symbol)
                .font(.dahliaSecondary)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
                .padding(.vertical, 6)
        }

        if !session.mcpServersNeedingSignIn.isEmpty {
            Label(L10n.chatMCPSignInRequired(session.mcpServersNeedingSignIn.formatted(.list(type: .and))), systemImage: "key.fill")
                .font(.dahliaBody)
                .foregroundStyle(DahliaDesign.secondaryTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
                .padding(.vertical, 6)
        }

        if let noticeMessage = session.noticeMessage {
            Label(noticeMessage, systemImage: "info.circle.fill")
                .font(.dahliaBody)
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

    private var emptyState: some View {
        CodexChatEmptyStateView(
            hasRecentThreads: !coordinator.history.isEmpty,
            showsProjectOrganizationShortcut: session.showsProjectOrganizationShortcut,
            isProjectOrganizationShortcutEnabled: session.canSendProjectOrganizationShortcut,
            onOrganizeRecentMeetingsAndProjects: { session.sendProjectOrganizationShortcut() },
            meetingReviewShortcutTitle: session.showsMeetingReviewShortcut
                ? CodexChatMeetingReviewShortcut.title
                : nil,
            isMeetingReviewShortcutEnabled: session.canSendMeetingReviewShortcut,
            onReviewMeeting: session.sendMeetingReviewShortcut,
            onShowAll: showHistory
        )
    }

    private var showsWelcome: Bool {
        !isSidePanel && showsEmptyState && !showsHistory
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
            catalogWorkspaceID: meetingCatalogWorkspaceID,
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
