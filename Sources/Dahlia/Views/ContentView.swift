import DahliaRuntimeSupport
import SwiftUI

/// ミーティング一覧サイドバーと詳細ビューを構成するルートビュー。
struct ContentView: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator
    var chatCoordinator: CodexChatCoordinator
    var onSelectVault: (VaultRecord) -> Void = { _ in }

    @Environment(\.openWindow) private var openWindow
    @AppStorage(PermissionGuidePresentationPolicy.userDefaultsKey)
    private var permissionGuidePresentationVersion = 0
    @AppStorage(AppSettings.customerIntelligenceBetaEnabledUserDefaultsKey)
    private var isCustomerIntelligenceBetaEnabled = AppSettings.defaultCustomerIntelligenceBetaEnabled
    @State private var navigationState = MainNavigationState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MainNavigationSidebar(
                selection: navigationRoute,
                projects: sidebarViewModel.flatProjects,
                showsOrganizations: isCustomerIntelligenceBetaEnabled,
                openProjectManager: { openWindow(id: WindowID.projectManager) },
                openOrganizationWindow: { openWindow(id: WindowID.organizationWorkspace) }
            )
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } content: {
            navigationContent
        } detail: {
            routedDetailView
                .navigationTitle("")
        }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(L10n.newMeeting, systemImage: "square.and.pencil") {
                    recordingCoordinator.createEmptyMeeting()
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut("n", modifiers: .command)
                .help(L10n.newMeeting)

            }

            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: floatingChatVisibility) {
                    Label(L10n.chat, systemImage: "bubble.left.and.bubble.right")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help(L10n.chat)
                .accessibilityLabel(L10n.chat)

                if recordingPlacement.showsToolbarStop {
                    Button(L10n.stopRecording, systemImage: "stop.fill") {
                        recordingCoordinator.stopRecording()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .help(L10n.stopRecording)
                }

                RecordToolbarButton(
                    viewModel: viewModel,
                    sidebarViewModel: sidebarViewModel,
                    recordingCoordinator: recordingCoordinator
                )
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .overlay {
            if chatCoordinator.isFloatingVisible {
                CodexChatFloatingView(
                    coordinator: chatCoordinator,
                    sidebarViewModel: sidebarViewModel,
                    onPopOut: openDetachedChat,
                    onOpenDetachedSession: openDetachedChat
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottomTrailing)))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !viewModel.summaryGenerationJobs.isEmpty {
                SummaryProgressToastView(
                    jobs: viewModel.summaryGenerationJobs,
                    onDismiss: viewModel.dismissSummaryGenerationJob
                )
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: viewModel.summaryGenerationJobs.map(\.id))
            }
        }
        .task {
            presentPermissionGuideIfNeeded()
        }
        .sheet(item: $viewModel.pendingBatchTranscriptionConfirmation) { confirmation in
            BatchTranscriptionConfirmationView(
                locales: viewModel.batchTranscriptionLocaleOptions(
                    preferredIdentifier: confirmation.suggestedLocaleIdentifier
                ),
                automaticLanguageLocales: viewModel.batchTranscriptionAutomaticLanguageCandidates(
                    snapshot: confirmation.automaticLanguageCandidateSnapshot
                ).locales,
                displayLocale: AppSettings.shared.appLanguage.locale,
                projects: confirmation.projectSelection.projects,
                initialProjectId: confirmation.projectSelection.selectedProjectId,
                initialErrorMessage: confirmation.projectSelection.errorMessage,
                initialLanguageSelection: confirmation.initialLanguageSelection,
                initiallyRetainsAudioAfterBatch: confirmation.retainAudioAfterBatch,
                initiallyGeneratesSummary: confirmation.initiallyGeneratesSummary,
                summaryGenerationOptions: AppSettings.shared.batchSummaryGenerationOptions,
                isRetranscription: confirmation.isRetranscription,
                onStart: { languageSelection, retainAudio, summaryOptions, projectId in
                    if let error = viewModel.assignPendingBatchTranscriptionProject(projectId) {
                        return error
                    }
                    viewModel.confirmBatchTranscription(
                        languageSelection: languageSelection,
                        retainAudioAfterBatch: retainAudio,
                        summaryGenerationOptions: summaryOptions
                    )
                    return nil
                },
                onPostpone: viewModel.postponeBatchTranscription
            )
            .interactiveDismissDisabled()
        }
        .onChange(of: sidebarViewModel.selectedMeetingIds) { oldValue, newValue in
            guard oldValue != newValue else { return }
            navigationState.selectMeetings(newValue)
            handleMeetingSelectionChange(newValue)
            syncChatContext()
        }
        .onChange(of: viewModel.currentMeetingId) { oldId, newId in
            guard oldId != newId else { return }
            if let newId, sidebarViewModel.selectedMeetingId != newId {
                sidebarViewModel.selectMeeting(newId)
            }
            syncChatContext()
        }
        .onChange(of: viewModel.draftMeeting) {
            syncChatContext()
        }
        .onChange(of: sidebarViewModel.currentVault?.id) { _, _ in
            sidebarViewModel.clearMeetingSelection()
            viewModel.clearCurrentMeeting()
            navigationState.resetForVaultChange()
            syncChatContext()
        }
        .onChange(of: sidebarViewModel.workspaceChangeToken) { _, _ in
            // MCP ヘルパーなど別プロセスが要約を書き換えた場合に Summary タブを追従させる。
            viewModel.reloadSummaryDocument()
        }
        .onChange(of: isCustomerIntelligenceBetaEnabled) { _, isEnabled in
            navigationState.reconcileOrganizationsAvailability(isEnabled)
        }
        .task { syncChatContext() }
    }

    private var navigationRoute: Binding<MainNavigationRoute> {
        Binding(
            get: { navigationState.route },
            set: { route in
                navigationState.select(route)
                if !route.showsMeetingList {
                    sidebarViewModel.clearMeetingSelection()
                    viewModel.clearCurrentMeeting()
                }
            }
        )
    }

    private var floatingChatVisibility: Binding<Bool> {
        Binding(
            get: { chatCoordinator.isFloatingVisible },
            set: { isVisible in
                if isVisible {
                    chatCoordinator.showFloating()
                } else {
                    chatCoordinator.hideFloating()
                }
            }
        )
    }

    private var isMeetingListVisible: Bool {
        navigationState.route.showsMeetingList && columnVisibility != .detailOnly
    }

    private var recordingPlacement: RecordingCommandPlacement {
        RecordingCommandPlacement(
            isListening: viewModel.isListening,
            isSidebarVisible: isMeetingListVisible,
            recordingMeetingID: viewModel.recordingMeetingId,
            currentMeetingID: viewModel.currentMeetingId
        )
    }

    @ViewBuilder
    private var navigationContent: some View {
        switch navigationState.route {
        case .meetings, .project:
            MeetingListSidebarView(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel,
                recordingCoordinator: recordingCoordinator,
                scopeProjectID: navigationState.route.projectID
            )
            .navigationTitle(projectScopeTitle ?? L10n.meetings)
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        case .schedule:
            ContentUnavailableView(L10n.calendarScheduleTitle, systemImage: "calendar")
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        case .organizations:
            ContentUnavailableView(L10n.organizations, systemImage: "building.2")
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        }
    }

    private var projectScopeTitle: String? {
        guard let projectID = navigationState.route.projectID else { return nil }
        return sidebarViewModel.flatProjects.first(where: { $0.id == projectID })?.displayName
    }

    @ViewBuilder
    private var routedDetailView: some View {
        switch navigationState.route {
        case .schedule:
            CalendarScheduleView(
                onSelectEvent: { event in
                    navigationState.select(.meetings)
                    recordingCoordinator.openCalendarEvent(event)
                },
                onCreateMeeting: recordingCoordinator.createEmptyMeeting
            )
        case .organizations:
            OrganizationWorkspaceView(
                sidebarViewModel: sidebarViewModel,
                chatCoordinator: chatCoordinator
            )
        case .meetings, .project:
            detailView
        }
    }

    private func presentPermissionGuideIfNeeded() {
        guard PermissionGuidePresentationPolicy.shouldPresent(
            storedVersion: permissionGuidePresentationVersion
        ) else { return }
        openWindow(id: WindowID.permissions)
    }

    private func openDetachedChat(_ sessionID: CodexChatSessionID) {
        openWindow(id: WindowID.codexChat, value: sessionID)
    }

    private func syncChatContext() {
        guard sidebarViewModel.selectedMeetingIds.count <= 1 else {
            chatCoordinator.updateCurrentContext(
                vaultID: sidebarViewModel.currentVault?.id,
                meetingID: nil,
                draftMeeting: nil,
                dbQueue: sidebarViewModel.dbQueue
            )
            return
        }

        let draftMeeting = viewModel.draftMeeting
        chatCoordinator.updateCurrentContext(
            vaultID: sidebarViewModel.currentVault?.id,
            meetingID: draftMeeting == nil
                ? viewModel.currentMeetingId ?? sidebarViewModel.selectedMeetingId
                : nil,
            draftMeeting: draftMeeting,
            dbQueue: sidebarViewModel.dbQueue
        )
    }

    @ViewBuilder
    private var detailView: some View {
        if sidebarViewModel.selectedMeetingIds.count > 1 {
            MultipleMeetingSelectionView(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel
            )
        } else if sidebarViewModel.selectedMeetingId != nil || viewModel.hasDraftMeeting || viewModel.currentMeetingId != nil {
            ControlPanelView(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel,
                recordingCoordinator: recordingCoordinator,
                allowsTranscriptReferencePopovers: !chatCoordinator.isFloatingVisible
            )
        } else {
            CalendarScheduleView(
                onSelectEvent: recordingCoordinator.openCalendarEvent,
                onCreateMeeting: recordingCoordinator.createEmptyMeeting
            )
        }
    }

    private func handleMeetingSelectionChange(_ selection: Set<UUID>) {
        guard selection.count == 1, let meetingId = selection.first else {
            if !selection.isEmpty || !viewModel.hasDraftMeeting {
                viewModel.clearCurrentMeeting()
            }
            return
        }
        handleMeetingSelection(meetingId)
    }

    private func handleMeetingSelection(_ meetingId: UUID) {
        guard let dbQueue = sidebarViewModel.dbQueue,
              let vault = sidebarViewModel.currentVault else { return }

        do {
            let repository = MeetingRepository(dbQueue: dbQueue)
            guard let meeting = try repository.fetchMeeting(id: meetingId) else { return }
            navigationState.reconcileSelectedMeetingProject(meeting.projectId)
            let project = try meeting.projectId.flatMap { try repository.fetchProject(id: $0) }
            viewModel.loadMeeting(
                meetingId,
                dbQueue: dbQueue,
                projectURL: project.map { vault.url.appending(path: $0.path, directoryHint: .isDirectory) },
                projectId: project?.id,
                projectName: project?.path,
                vaultURL: vault.url
            )
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}
