import DahliaRuntimeSupport
import SwiftUI

/// ミーティング一覧サイドバーと詳細ビューを構成するルートビュー。
struct ContentView: View {
    @ObservedObject var viewModel: CaptionViewModel
    var updateController: AppUpdateController
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator
    var chatCoordinator: CodexChatCoordinator
    @Bindable var mainWindowNavigation: MainWindowNavigation
    let appDatabase: AppDatabaseManager?
    var vaultManagementModel: VaultManagementModel
    var onSelectVault: (VaultRecord) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PermissionGuidePresentationPolicy.userDefaultsKey)
    private var permissionGuidePresentationVersion = 0
    @AppStorage(AppSettings.customerIntelligenceBetaEnabledUserDefaultsKey)
    private var isCustomerIntelligenceBetaEnabled = AppSettings.defaultCustomerIntelligenceBetaEnabled
    @State private var isSidebarVisible = true
    @State private var isShowingUnprocessedRecordings = false
    @State private var isShowingChatHistory = false
    @State private var isShowingChatConfiguration = false
    @State private var searchModel = MainSearchModel()
    @State private var isShowingProjectCreation = false
    @State private var projectCreationParentId: UUID?
    @State private var newProjectName = ""
    @State private var newProjectType = ProjectType.undefined
    @State private var projectCreationErrorMessage = ""

    var body: some View {
        let isShowingSettings = mainWindowNavigation.isShowingSettings

        HSplitView {
            Group {
                if mainWindowNavigation.section == .projects {
                    ProjectManagementView(
                        isSidebarVisible: $isSidebarVisible,
                        sidebarViewModel: sidebarViewModel,
                        captionViewModel: viewModel,
                        updateController: updateController,
                        recordingCoordinator: recordingCoordinator,
                        mainWindowNavigation: mainWindowNavigation,
                        appDatabase: appDatabase,
                        vaultManagementModel: vaultManagementModel,
                        onShowUpcomingSchedule: returnToCalendarSchedule,
                        onShowUnprocessedRecordings: showUnprocessedRecordings,
                        showsCustomerIntelligence: isCustomerIntelligenceBetaEnabled,
                        onOpenCustomerIntelligence: { openWindow(id: WindowID.organizationWorkspace) },
                        onCreateProject: presentProjectCreation,
                        onSelectVault: onSelectVault
                    )
                } else {
                    MainSidebarSplitView(
                        width: mainWindowNavigation.sidebarWidth,
                        isVisible: isSidebarVisible || isShowingSettings,
                        onWidthChange: mainWindowNavigation.updateSidebarWidth
                    ) {
                        MainWindowPaneContent(
                            isShowingSettings: isShowingSettings,
                            settingsBackground: .sidebar
                        ) {
                            MeetingListSidebarView(
                                viewModel: viewModel,
                                updateController: updateController,
                                sidebarViewModel: sidebarViewModel,
                                recordingCoordinator: recordingCoordinator,
                                isShowingUpcomingSchedule: isShowingUpcomingSchedule,
                                onShowUpcomingSchedule: returnToCalendarSchedule,
                                onOpenProjectManagement: showProjectManagement,
                                isShowingUnprocessedRecordings: isShowingUnprocessedRecordings,
                                onShowUnprocessedRecordings: showUnprocessedRecordings,
                                showsCustomerIntelligence: isCustomerIntelligenceBetaEnabled,
                                onOpenCustomerIntelligence: { openWindow(id: WindowID.organizationWorkspace) },
                                onCreateProject: presentProjectCreation,
                                onSelectVault: onSelectVault
                            )
                        } settingsContent: {
                            SettingsSidebarView(
                                selection: $mainWindowNavigation.settingsCategory,
                                onReturnToApp: mainWindowNavigation.dismissSettings
                            )
                        }
                    } detail: {
                        MainWindowPaneContent(isShowingSettings: isShowingSettings) {
                            detailView
                        } settingsContent: {
                            SettingsDetailView(
                                selection: mainWindowNavigation.settingsCategory,
                                captionViewModel: viewModel,
                                sidebarViewModel: sidebarViewModel,
                                appDatabase: appDatabase,
                                vaultManagementModel: vaultManagementModel
                            )
                        }
                        .mainDetailPane()
                    }
                }
            }
            .layoutPriority(1)
            .overlay(alignment: .top) {
                MainWorkspaceHeader(
                    isVisible: !isShowingSettings,
                    isSidebarVisible: isSidebarVisible,
                    isChatSidebarVisible: chatCoordinator.isDockedVisible,
                    canGoBack: canGoBack,
                    canGoForward: canGoForward,
                    onToggleSidebar: toggleSidebar,
                    onSearch: showSearch,
                    onGoBack: goBack,
                    onGoForward: goForward,
                    onToggleChat: toggleChat
                )
            }

            if chatCoordinator.isDockedVisible {
                CodexChatSidebarView(
                    coordinator: chatCoordinator,
                    sidebarViewModel: sidebarViewModel,
                    showsHistory: $isShowingChatHistory,
                    showsConfiguration: $isShowingChatConfiguration,
                    onPopOut: popOutDockedChat,
                    onClose: toggleChat,
                    onOpenDetachedSession: openDetachedChat
                )
                .mainChatSidebarPane(
                    width: mainWindowNavigation.chatSidebarWidth,
                    isVisible: !isShowingSettings,
                    onWidthChange: mainWindowNavigation.updateChatSidebarWidth
                )
            }
        }
        .allowsHitTesting(!searchModel.isPresented || isShowingSettings)
        .overlay(alignment: .bottomTrailing) {
            if !viewModel.summaryGenerationJobs.isEmpty {
                SummaryProgressToastView(
                    jobs: viewModel.summaryGenerationJobs,
                    onDismiss: viewModel.dismissSummaryGenerationJob
                )
                .padding(16)
                .opacity(isShowingSettings ? 0 : 1)
                .allowsHitTesting(!isShowingSettings)
                .disabled(isShowingSettings)
                .accessibilityHidden(isShowingSettings)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: viewModel.summaryGenerationJobs.map(\.id))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if chatCoordinator.isDockedVisible {
                CodexChatConfigurationOverlay(
                    session: chatCoordinator.dockedSession,
                    isPresented: $isShowingChatConfiguration
                )
                .opacity(isShowingSettings ? 0 : 1)
                .allowsHitTesting(!isShowingSettings)
                .disabled(isShowingSettings)
                .accessibilityHidden(isShowingSettings)
            }
        }
        .overlay {
            if searchModel.isPresented {
                MainSearchOverlay(
                    model: searchModel,
                    sidebarViewModel: sidebarViewModel,
                    onOpenMeeting: openSearchMeeting,
                    onOpenProject: openSearchProject
                )
                .opacity(isShowingSettings ? 0 : 1)
                .allowsHitTesting(!isShowingSettings)
                .disabled(isShowingSettings)
                .accessibilityHidden(isShowingSettings)
            }
        }
        .sheet(isPresented: $isShowingProjectCreation) {
            ProjectCreationSheet(
                parentProjects: projectCreationParentProjects,
                parentProjectId: $projectCreationParentId,
                projectName: $newProjectName,
                projectType: $newProjectType,
                errorMessage: projectCreationErrorMessage,
                onCancel: dismissProjectCreation,
                onCreate: createProject
            )
        }
        .task {
            presentPermissionGuideIfNeeded()
        }
        .task(id: sidebarViewModel.currentVault?.id) {
            await sidebarViewModel.refreshUnprocessedRecordings()
        }
        .onChange(of: sidebarViewModel.currentVault?.id) {
            isShowingChatHistory = false
            dismissChatConfiguration()
            searchModel.resetForVaultChange(using: sidebarViewModel)
            syncChatContext()
        }
        .onChange(of: viewModel.batchTranscriptionState) { _, state in
            guard state?.changesUnprocessedRecordingsProjection != false else { return }
            Task { await sidebarViewModel.refreshUnprocessedRecordings() }
        }
        .onChange(of: viewModel.offscreenBatchTranscriptionChangeToken) { _, _ in
            Task { await sidebarViewModel.refreshUnprocessedRecordings() }
        }
        .alert(item: $viewModel.batchTranscriptionRecoveryAlert) { alert in
            Alert(
                title: Text(L10n.batchTranscriptionRecoveryFailedTitle),
                message: Text(alert.message),
                primaryButton: .default(Text(L10n.retry), action: viewModel.retryBatchTranscriptionRecovery),
                secondaryButton: .cancel()
            )
        }
        .onChange(of: sidebarViewModel.selectedMeetingIds) { oldValue, newValue in
            guard oldValue != newValue else { return }
            if !newValue.isEmpty {
                mainWindowNavigation.showMeetings()
                isShowingUnprocessedRecordings = false
            }
            if newValue.count == 1, let meetingID = newValue.first {
                mainWindowNavigation.recordNavigation(to: .meeting(meetingID))
            }
            if newValue.count != 1 {
                if !newValue.isEmpty || !viewModel.hasDraftMeeting {
                    viewModel.clearCurrentMeeting()
                }
            }
            if newValue.isEmpty {
                mainWindowNavigation.recordUpcomingScheduleIfVisible(isShowingUpcomingSchedule)
            }
            syncChatContext()
        }
        .onChange(of: sidebarViewModel.selectedMeetingDetail) { _, _ in
            loadSelectedMeetingIfPossible()
        }
        .onChange(of: canLoadSelectedMeeting) { _, canLoad in
            guard canLoad else { return }
            loadSelectedMeetingIfPossible()
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
        .onChange(of: mainWindowNavigation.selectedProjectId) { _, projectID in
            guard mainWindowNavigation.section == .projects else { return }
            mainWindowNavigation.recordNavigation(to: .project(projectID))
        }
        .onChange(of: mainWindowNavigation.section) { _, section in
            if section == .projects {
                prepareProjectManagement()
            } else {
                syncChatContext()
            }
        }
        .onChange(of: sidebarViewModel.workspaceChangeToken) { _, _ in
            // MCP ヘルパーなど別プロセスが要約を書き換えた場合に Summary タブを追従させる。
            viewModel.reloadSummaryDocument()
        }
        .onAppear {
            prepareInitialPresentation()
        }
        .task { syncChatContext() }
    }
}

private extension ContentView {
    private func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    private func toggleChat() {
        if chatCoordinator.isDockedVisible {
            isShowingChatHistory = false
            dismissChatConfiguration()
            chatCoordinator.hideDocked()
        } else {
            chatCoordinator.showDocked()
        }
    }

    private func popOutDockedChat() {
        isShowingChatHistory = false
        dismissChatConfiguration()
        openDetachedChat(chatCoordinator.popOutDocked())
    }

    private func dismissChatConfiguration() {
        isShowingChatConfiguration = false
    }

    private func showSearch() {
        searchModel.present(using: sidebarViewModel)
    }

    private func openSearchMeeting(_ id: UUID) {
        mainWindowNavigation.showMeetings()
        isShowingUnprocessedRecordings = false
        sidebarViewModel.selectMeeting(id)
    }

    private func openSearchProject(_ id: UUID) {
        if let project = sidebarViewModel.allProjectItems.first(where: { $0.projectId == id }) {
            let ancestorIds = ProjectManagementSelection.ancestorIDs(
                toReveal: project.projectName,
                projects: sidebarViewModel.allProjectItems
            )
            mainWindowNavigation.expandedProjectIds.formUnion(ancestorIds)
        }
        mainWindowNavigation.selectedProjectId = id
        mainWindowNavigation.recordNavigation(to: .project(id))
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
        if mainWindowNavigation.section == .projects {
            chatCoordinator.updateCurrentContext(
                vaultID: sidebarViewModel.currentVault?.id,
                meetingID: nil,
                draftMeeting: nil,
                dbQueue: sidebarViewModel.dbQueue
            )
            return
        }
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
                ? sidebarViewModel.selectedMeetingId ?? viewModel.currentMeetingId
                : nil,
            draftMeeting: draftMeeting,
            dbQueue: sidebarViewModel.dbQueue
        )
    }

    private var isShowingUpcomingSchedule: Bool {
        sidebarViewModel.selectedMeetingIds.isEmpty
            && !viewModel.hasDraftMeeting
            && viewModel.currentMeetingId == nil
            && !isShowingUnprocessedRecordings
    }

    private var canGoBack: Bool {
        mainWindowNavigation.canGoBack && canNavigateHistory
    }

    private var canGoForward: Bool { mainWindowNavigation.canGoForward && canNavigateHistory }

    private var hasMeetingDetail: Bool { viewModel.hasDraftMeeting || viewModel.currentMeetingId != nil }

    private var canLoadSelectedMeeting: Bool {
        Self.canLoadMeetingSelection(
            isRecordingStartPending: viewModel.isRecordingStartPending,
            isFinalizingRecording: viewModel.isFinalizingRecording
        )
    }

    private var canNavigateHistory: Bool {
        !viewModel.hasDraftMeeting
            && !viewModel.isRecordingStartPending
            && !viewModel.isFinalizingRecording
    }

    @ViewBuilder
    private var detailView: some View {
        if isShowingUnprocessedRecordings {
            UnprocessedRecordingsView(
                items: sidebarViewModel.unprocessedRecordingItems,
                captionViewModel: viewModel,
                sidebarViewModel: sidebarViewModel
            )
        } else if sidebarViewModel.selectedMeetingIds.count > 1 {
            MultipleMeetingSelectionView(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel
            )
        } else if Self.isMeetingSelectionPending(
            selectedMeetingID: sidebarViewModel.selectedMeetingId,
            currentMeetingID: viewModel.currentMeetingId
        ) {
            meetingLoadingPlaceholder
        } else if hasMeetingDetail {
            ControlPanelView(
                viewModel: viewModel,
                sidebarViewModel: sidebarViewModel,
                recordingCoordinator: recordingCoordinator
            )
        } else {
            CalendarScheduleView(
                onSelectEvent: recordingCoordinator.openCalendarEvent,
                onJoinEvent: recordingCoordinator.openMeetingLink
            )
        }
    }

    @ViewBuilder
    private var meetingLoadingPlaceholder: some View {
        if let error = sidebarViewModel.selectedMeetingDetailLoadError {
            ContentUnavailableView {
                Label(L10n.meetingListLoadFailed, systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(L10n.retry, action: sidebarViewModel.startSelectedMeetingObservationIfNeeded)
            }
        } else {
            ProgressView(L10n.loadingMeetings)
        }
    }

    private func returnToCalendarSchedule() {
        mainWindowNavigation.recordNavigation(to: .upcomingSchedule)
        displayUpcomingSchedule()
    }

    private func showUnprocessedRecordings() {
        mainWindowNavigation.recordNavigation(to: .unprocessedRecordings)
        displayUnprocessedRecordings()
    }

    private func displayUpcomingSchedule() {
        mainWindowNavigation.showMeetings()
        isShowingUnprocessedRecordings = false
        if viewModel.hasDraftMeeting || sidebarViewModel.selectedMeetingIds.isEmpty {
            viewModel.clearCurrentMeeting()
        }
        sidebarViewModel.clearMeetingSelection()
    }

    private func displayUnprocessedRecordings() {
        mainWindowNavigation.showMeetings()
        viewModel.clearCurrentMeeting()
        sidebarViewModel.clearMeetingSelection()
        isShowingUnprocessedRecordings = true
        Task { await sidebarViewModel.refreshUnprocessedRecordings() }
    }

    private func showProjectManagement() {
        mainWindowNavigation.recordNavigation(to: .project(mainWindowNavigation.selectedProjectId))
        mainWindowNavigation.showProjects()
    }

    private var projectCreationParentProjects: [ProjectOverviewItem] {
        sidebarViewModel.allProjectItems.filter { $0.parentProjectId == nil }
    }

    private func presentProjectCreation() {
        projectCreationParentId = nil
        newProjectName = ""
        newProjectType = .undefined
        projectCreationErrorMessage = ""
        isShowingProjectCreation = true
    }

    private func dismissProjectCreation() {
        isShowingProjectCreation = false
        projectCreationParentId = nil
        projectCreationErrorMessage = ""
    }

    private func createProject() {
        let projectName = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectName.isEmpty else { return }

        guard let project = sidebarViewModel.createProject(
            name: projectName,
            parentProjectId: projectCreationParentId,
            projectType: projectCreationParentId == nil ? newProjectType : nil
        ) else {
            projectCreationErrorMessage = sidebarViewModel.lastError ?? L10n.projectCreationFailedDescription
            return
        }

        mainWindowNavigation.selectCreatedProject(project.id)
        mainWindowNavigation.expandedProjectIds.formUnion(
            ProjectManagementSelection.ancestorIDs(
                toReveal: project.path,
                projects: sidebarViewModel.allProjectItems
            )
        )
        dismissProjectCreation()
        showProjectManagement()
    }

    private func prepareProjectManagement() {
        isShowingUnprocessedRecordings = false
        viewModel.clearCurrentMeetingForProjectNavigation()
        sidebarViewModel.clearMeetingSelection()
        syncChatContext()
    }

    private func prepareInitialPresentation() {
        if mainWindowNavigation.hasInitializedNavigationHistory {
            restoreCurrentPresentation()
            return
        }
        if mainWindowNavigation.section == .projects {
            prepareProjectManagement()
            mainWindowNavigation.initializeNavigationHistoryIfNeeded(
                to: .project(mainWindowNavigation.selectedProjectId)
            )
            return
        }
        if sidebarViewModel.selectedMeetingIds.count == 1,
           let detail = sidebarViewModel.selectedMeetingDetail,
           viewModel.currentMeetingId != detail.meetingId {
            handleMeetingSelection(detail)
        }
        let initialLocation = sidebarViewModel.selectedMeetingId.map(MainWindowLocation.meeting)
            ?? .upcomingSchedule
        mainWindowNavigation.initializeNavigationHistoryIfNeeded(to: initialLocation)
        syncChatContext()
    }

    private func restoreCurrentPresentation() {
        if viewModel.hasDraftMeeting || sidebarViewModel.selectedMeetingIds.count > 1 {
            mainWindowNavigation.showMeetings()
            isShowingUnprocessedRecordings = false
            syncChatContext()
            return
        }

        restoreNavigation(mainWindowNavigation.currentLocation)
        syncChatContext()
    }

    private func goBack() {
        guard canNavigateHistory else { return }
        Task {
            await mainWindowNavigation.goBack(
                validatingWith: validateNavigation,
                restoringWith: restoreNavigation
            )
        }
    }

    private func goForward() {
        guard canNavigateHistory else { return }
        Task {
            await mainWindowNavigation.goForward(
                validatingWith: validateNavigation,
                restoringWith: restoreNavigation
            )
        }
    }

    private func validateNavigation(_ location: MainWindowLocation) async -> Bool {
        switch location {
        case .upcomingSchedule, .unprocessedRecordings:
            return true
        case let .meeting(meetingID):
            let selectedMeetingIds = sidebarViewModel.selectedMeetingIds
            let draftMeeting = viewModel.draftMeeting
            let currentMeetingID = viewModel.currentMeetingId
            let isRecordingStartPending = viewModel.isRecordingStartPending
            let isFinalizingRecording = viewModel.isFinalizingRecording
            let exists = await sidebarViewModel.containsMeeting(id: meetingID)
            guard canNavigateHistory,
                  sidebarViewModel.selectedMeetingIds == selectedMeetingIds,
                  viewModel.draftMeeting == draftMeeting,
                  viewModel.currentMeetingId == currentMeetingID,
                  viewModel.isRecordingStartPending == isRecordingStartPending,
                  viewModel.isFinalizingRecording == isFinalizingRecording else {
                mainWindowNavigation.cancelHistoryNavigation()
                return false
            }
            return exists
        case let .project(projectID):
            return projectID == nil
                || sidebarViewModel.allProjectItems.contains(where: { $0.projectId == projectID })
        }
    }

    private func restoreNavigation(_ location: MainWindowLocation) {
        switch location {
        case .upcomingSchedule:
            displayUpcomingSchedule()
        case .unprocessedRecordings:
            displayUnprocessedRecordings()
        case let .meeting(meetingID):
            mainWindowNavigation.showMeetings()
            isShowingUnprocessedRecordings = false
            sidebarViewModel.selectMeeting(meetingID)
        case let .project(projectID):
            mainWindowNavigation.showProjects()
            mainWindowNavigation.selectedProjectId = projectID
        }
    }

    private func handleMeetingSelection(_ detail: MeetingDetailItem) {
        guard let dbQueue = sidebarViewModel.dbQueue,
              let vault = sidebarViewModel.currentVault,
              sidebarViewModel.selectedMeetingId == detail.meetingId,
              detail.vaultId == vault.id else { return }

        viewModel.loadMeeting(
            detail.meetingId,
            dbQueue: dbQueue,
            projectURL: detail.projectName.map { vault.url.appending(path: $0, directoryHint: .isDirectory) },
            projectId: detail.projectId,
            projectName: detail.projectName,
            vaultURL: vault.url
        )
    }

    private func loadSelectedMeetingIfPossible() {
        guard canLoadSelectedMeeting,
              let detail = sidebarViewModel.selectedMeetingDetail,
              detail.meetingId != viewModel.currentMeetingId else { return }
        handleMeetingSelection(detail)
    }
}

extension ContentView {
    static func canLoadMeetingSelection(
        isRecordingStartPending: Bool,
        isFinalizingRecording: Bool
    ) -> Bool {
        !isRecordingStartPending && !isFinalizingRecording
    }

    static func isMeetingSelectionPending(
        selectedMeetingID: UUID?,
        currentMeetingID: UUID?
    ) -> Bool {
        selectedMeetingID != nil && selectedMeetingID != currentMeetingID
    }
}
