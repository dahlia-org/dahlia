import SwiftUI

struct CodexChatView: View {
    @Bindable var session: CodexChatSessionModel
    @Bindable var coordinator: CodexChatCoordinator
    let sidebarViewModel: SidebarViewModel
    let meetingReferences: [CodexChatMeetingReference]
    let meetingCatalogWorkspaceID: UUID?
    let isMeetingCatalogLoaded: Bool
    @Binding var showsHistory: Bool
    var configurationPresentation: Binding<Bool>?
    let onNewChat: () -> Void
    let onOpenHistory: (CodexChatThreadSummary) -> Void
    let onShowFullScreen: (() -> Void)?
    let reservesSidebarToggle: Bool
    let reservesWindowControls: Bool
    let headerLeadingInset: CGFloat
    let contentMaxWidth: CGFloat?
    /// The side panel leaves out the title and keeps a new chat's composer at the bottom, as in a conversation. Elsewhere a
    /// new chat centers its composer under a welcome.
    var isSidePanel = false
    /// The agent whose thread this is: its conversation keeps the composer at the bottom even while empty.
    var agent: AgentRecord?

    @Environment(MainWindowNavigation.self) private var navigation
    @State private var dismissedIntegrationsSessionID: CodexChatSessionID?

    var body: some View {
        VStack(spacing: 0) {
            CodexChatHeader(
                title: session.displayTitle,
                showsHistory: showsHistory,
                hasConversation: !session.messages.isEmpty,
                onBack: hideHistory,
                onNewChat: startNewChat,
                onShowFullScreen: onShowFullScreen,
                reservesSidebarToggle: reservesSidebarToggle,
                reservesWindowControls: reservesWindowControls,
                leadingInset: headerLeadingInset,
                showsTitle: !isSidePanel || session.parentThread != nil || session.intakeAgent != nil,
                parentTitle: session.parentThread.map {
                    CodexChatMeetingReference.displayText(for: $0.title.nilIfBlank ?? L10n.newChat, namesByID: session.meetingNamesByID)
                },
                onOpenParent: session.parentThread.map { parent in { openHistoryThread(parent) } },
                agent: agent ?? session.intakeAgent,
                agentThreadTitle: agent == nil ? session.intakeAgent.map { _ in session.displayTitle } : nil
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
                            contentMaxWidth: contentMaxWidth,
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
                            messages: session.conversationMessages,
                            showsStandaloneThinking: session.showsStandaloneThinking,
                            meetingNamesByID: session.meetingNamesByID,
                            meetingReferencesByID: session.meetingReferencesByID,
                            contentMaxWidth: contentMaxWidth,
                            hasStoredEarlierMessages: session.earlierMessagesCursor != nil,
                            isLoadingEarlierMessages: session.isLoadingEarlierMessages,
                            canLoadEarlierMessages: !session.isGenerating && !session.isRestoring,
                            onLoadEarlierMessages: { await session.loadEarlierMessages() },
                            parentThreadID: session.backendThreadID,
                            currentRunID: session.runtimeState?.turnID,
                            agent: agent,
                            coordinator: coordinator,
                            onOpenThread: openHistoryThread
                        )
                    }

                    if let errorMessage = session.errorMessage {
                        CodexChatErrorView(
                            message: errorMessage,
                            onRetry: session.hasRetryableSubmission ? session.retry : retryConnection,
                            onSkipAndContinue: session.canSkipFailedSubmission ? { session.skipFailedSubmissionAndResumeQueue() } : nil
                        )
                        .frame(maxWidth: contentMaxWidth ?? .infinity)
                    } else if let earlierMessagesError = session.earlierMessagesError {
                        CodexChatErrorView(message: earlierMessagesError, onRetry: {
                            Task { await session.loadEarlierMessages() }
                        })
                        .frame(maxWidth: contentMaxWidth ?? .infinity)
                    } else if let historyError = coordinator.historyError, showsHistory || showsEmptyState {
                        CodexChatErrorView(
                            message: historyError,
                            onRetry: retryHistory
                        )
                        .frame(maxWidth: contentMaxWidth ?? .infinity)
                    }

                    if !showsHistory {
                        // Keep one composer in the view tree, preserving focus and attachments when the first message is sent.
                        conversationControls
                            .frame(maxWidth: contentMaxWidth ?? .infinity)
                    }

                    if showsWelcome {
                        if dismissedIntegrationsSessionID != session.id {
                            CodexChatAppIntegrationsView(
                                onOpenSettings: { navigation.openSettings(category: .mcp) },
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
                .frame(maxWidth: showsWelcome ? (contentMaxWidth ?? .infinity) : .infinity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(name: CodexChatAddPanelLayout.coordinateSpaceName)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .scrollEdgeEffectHidden()
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
        if !session.pendingManualInputs.isEmpty {
            VStack(alignment: .trailing, spacing: 0) {
                HStack {
                    Spacer()
                    Label(session.isQueuePaused ? L10n.chatQueuePaused : L10n.chatQueue, systemImage: "clock")
                    if session.isQueuePaused {
                        Button(L10n.chatResumeQueue, action: session.resumeQueue)
                            .buttonStyle(.borderless)
                    }
                }
                .font(.dahliaSecondary)
                .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.pendingManualInputs) { input in
                            CodexChatQueuedInputRow(session: session, input: input)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }

        if session.startsFreshSession {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.chatFreshSessionArmed).foregroundStyle(.primary)
                        Text(L10n.chatFreshSessionArmedDetail).font(.dahliaSecondary)
                    }
                } icon: {
                    Image(systemName: "eraser")
                }
                Spacer()
                CodexChatIconButton(label: L10n.chatKeepCurrentSession, systemImage: "xmark") {
                    session.startsFreshSession = false
                }
            }
            .font(.dahliaBody)
            .foregroundStyle(DahliaDesign.secondaryTextColor)
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

        CodexChatScopeBar(
            session: session,
            sidebarViewModel: sidebarViewModel
        )

        if session.isReadOnly {
            HStack {
                Text(L10n.agentScheduleReadOnly).foregroundStyle(.secondary)
                Spacer()
                if session.isGenerating {
                    CodexChatActionButton(
                        label: L10n.stopGenerating,
                        systemImage: "stop.fill",
                        isEnabled: !session.isTurnCleanupPending,
                        action: session.stop
                    )
                }
            }
            .font(.dahliaBody)
            .padding()
        } else if let request = session.pendingUserInput {
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
        session.messages.isEmpty && session.earlierMessagesCursor == nil && !session.showsStandaloneThinking
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
        !isSidePanel && agent == nil && showsEmptyState && !showsHistory
    }

    private func prepare() async {
        updateMeetingCatalog()
        await coordinator.restoreSession(session)
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
        Task { await coordinator.restoreSession(session) }
    }

    private func retryHistory() {
        Task { await coordinator.refreshHistory() }
    }
}
