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
    @State private var projectEditorRequest: ProjectEditorRequest?
    @State private var projectPendingDeletion: ProjectOverviewItem?

    var body: some View {
        let isShowingSettings = mainWindowNavigation.isShowingSettings

        MainChatSplitView(
            width: mainWindowNavigation.chatSidebarWidth,
            contentMinimumWidth: isSidebarVisible || isShowingSettings
                ? MainSidebarLayout.minimumSplitWidth
                : MainSidebarLayout.minimumDetailWidth,
            isVisible: chatCoordinator.isDockedVisible && !isShowingSettings,
            onWidthChange: mainWindowNavigation.updateChatSidebarWidth
        ) {
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
                        onOpenProject: openProjectDetail,
                        onOpenMeeting: openProjectMeeting,
                        onShowProjectCatalog: showProjectCatalog,
                        onEditProject: presentProjectEditor,
                        onRequestProjectDeletion: { projectPendingDeletion = $0 },
                        onOpenSidebarProject: handleMeetingSidebarProjectAction,
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
                                mainWindowNavigation: mainWindowNavigation,
                                recordingCoordinator: recordingCoordinator,
                                isShowingUpcomingSchedule: isShowingUpcomingSchedule,
                                onShowUpcomingSchedule: returnToCalendarSchedule,
                                isShowingProjects: false,
                                onShowProjects: showProjectCatalog,
                                isShowingUnprocessedRecordings: isShowingUnprocessedRecordings,
                                onShowUnprocessedRecordings: showUnprocessedRecordings,
                                showsCustomerIntelligence: isCustomerIntelligenceBetaEnabled,
                                onOpenCustomerIntelligence: { openWindow(id: WindowID.organizationWorkspace) },
                                onCreateProject: presentProjectCreation,
                                onOpenProject: handleMeetingSidebarProjectAction,
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
                    canGoBack: canGoBack,
                    canGoForward: canGoForward,
                    onToggleSidebar: toggleSidebar,
                    onSearch: showSearch,
                    onGoBack: goBack,
                    onGoForward: goForward
                )
            }
            .meetingSidebarHoverOverlay(
                sidebarViewModel: sidebarViewModel,
                isVisible: !isShowingSettings,
                onOpenProject: openProjectDetail,
                onEditProject: { handleMeetingSidebarProjectAction($0, .edit) },
                onToggleProjectPin: {
                    mainWindowNavigation.toggleProjectPin($0, vaultId: sidebarViewModel.currentVault?.id)
                }
            )
            .mainSidebarHelpOverlay(isVisible: !isShowingSettings)

        } sidebar: {
            CodexChatSidebarView(
                coordinator: chatCoordinator,
                sidebarViewModel: sidebarViewModel,
                showsHistory: $isShowingChatHistory,
                showsConfiguration: $isShowingChatConfiguration,
                onPopOut: popOutDockedChat,
                onOpenDetachedSession: openDetachedChat
            )
        }
        .allowsHitTesting(!searchModel.isPresented || isShowingSettings)
        .disabled(searchModel.isPresented && !isShowingSettings)
        .overlay(alignment: .topTrailing) {
            if !isShowingSettings {
                DahliaWindowHeader(allowsWindowDragging: false, backgroundColor: .clear) {
                    DahliaWindowHeaderIconButton(
                        label: chatCoordinator.isDockedVisible ? L10n.hideChat : L10n.showChat,
                        systemImage: "sidebar.right",
                        action: toggleChat
                    )
                    .accessibilityValue(chatCoordinator.isDockedVisible ? L10n.shown : L10n.hidden)
                }
                .frame(width: DahliaDesign.windowHeaderControlSize + 2 * DahliaDesign.windowHeaderHorizontalPadding)
            }
        }
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
                    appearanceForProject: { projectId in
                        mainWindowNavigation.projectAppearance(
                            projectId: projectId,
                            vaultId: sidebarViewModel.currentVault?.id
                        )
                    },
                    onOpenMeeting: openSearchMeeting,
                    onOpenProject: openSearchProject
                )
                .opacity(isShowingSettings ? 0 : 1)
                .allowsHitTesting(!isShowingSettings)
                .disabled(isShowingSettings)
                .accessibilityHidden(isShowingSettings)
            }
        }
        .projectModalPresentation(
            editorRequest: $projectEditorRequest,
            deletionProject: $projectPendingDeletion,
            projects: sidebarViewModel.allProjectItems,
            appearanceForProject: projectAppearance,
            onCancelEditor: dismissProjectEditor,
            onDeleteFromEditor: requestProjectDeletionFromEditor,
            onSave: saveProjectEditor,
            onCancelDeletion: dismissProjectDeletion,
            onConfirmDeletion: deleteProject
        )
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
        openProjectDetail(id)
    }

    private func handleMeetingSidebarProjectAction(_ id: UUID, _ intent: ProjectNavigationIntent) {
        guard let project = sidebarViewModel.allProjectItems.first(where: { $0.projectId == id }) else { return }
        switch intent {
        case .edit:
            presentProjectEditor(project)
        case .delete:
            projectPendingDeletion = project
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
        if mainWindowNavigation.section == .projects {
            let projectID: UUID? = if case let .project(id) = mainWindowNavigation.currentLocation { id } else { nil }
            chatCoordinator.updateCurrentContext(
                vaultID: sidebarViewModel.currentVault?.id,
                meetingID: nil,
                projectID: projectID,
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

    private func showProjectCatalog() {
        mainWindowNavigation.recordNavigation(to: .projects)
        syncChatContext()
    }

    private func openProjectDetail(_ id: UUID) {
        mainWindowNavigation.recordNavigation(to: .project(id))
        syncChatContext()
    }

    private func openProjectMeeting(_ id: UUID) {
        mainWindowNavigation.showMeetings()
        sidebarViewModel.selectMeeting(id)
    }

    private func presentProjectCreation() {
        projectEditorRequest = .create
    }

    private func presentProjectEditor(_ project: ProjectOverviewItem) {
        projectEditorRequest = .edit(project)
    }

    private func dismissProjectEditor() {
        projectEditorRequest = nil
    }

    private func requestProjectDeletionFromEditor(_ project: ProjectOverviewItem) {
        projectPendingDeletion = project
    }

    private func dismissProjectDeletion() {
        projectPendingDeletion = nil
    }

    private func saveProjectEditor(
        request: ProjectEditorRequest,
        name: String,
        description: String,
        parentProjectId: UUID?,
        projectType: ProjectType,
        appearance: ProjectAppearance
    ) async -> String? {
        switch request {
        case .create:
            createProject(
                name: name,
                description: description,
                parentProjectId: parentProjectId,
                projectType: projectType,
                appearance: appearance
            )
        case let .edit(project):
            await updateProject(
                project,
                name: name,
                description: description,
                parentProjectId: parentProjectId,
                projectType: projectType,
                appearance: appearance,
                expectedRevision: project.revision
            )
        }
    }

    private func createProject(
        name: String,
        description: String,
        parentProjectId: UUID?,
        projectType: ProjectType,
        appearance: ProjectAppearance
    ) -> String? {
        guard let project = sidebarViewModel.createProject(
            name: name,
            parentProjectId: parentProjectId,
            projectType: parentProjectId == nil ? projectType : nil,
            description: description
        ) else {
            return sidebarViewModel.lastError ?? L10n.projectCreationFailedDescription
        }

        mainWindowNavigation.setProjectAppearance(
            appearance,
            projectId: project.id,
            vaultId: sidebarViewModel.currentVault?.id
        )
        dismissProjectEditor()
        showProjectCatalog()
        return nil
    }

    private func updateProject(
        _ project: ProjectOverviewItem,
        name: String,
        description: String,
        parentProjectId: UUID?,
        projectType: ProjectType,
        appearance: ProjectAppearance,
        expectedRevision: Int
    ) async -> String? {
        let projectDataChanged = name != projectDisplayName(project)
            || description != project.projectDescription
            || parentProjectId != project.parentProjectId
            || (parentProjectId == nil && projectType != project.effectiveProjectType)
        if projectDataChanged {
            guard await sidebarViewModel.updateProject(
                id: project.projectId,
                name: name,
                parentProjectId: parentProjectId,
                projectType: projectType,
                description: description,
                expectedRevision: expectedRevision
            ) != nil else {
                return sidebarViewModel.lastError ?? L10n.projectOperationFailedDescription
            }
        }

        mainWindowNavigation.setProjectAppearance(
            appearance,
            projectId: project.projectId,
            vaultId: sidebarViewModel.currentVault?.id
        )
        dismissProjectEditor()
        return nil
    }

    private func projectAppearance(_ project: ProjectOverviewItem) -> ProjectAppearance {
        mainWindowNavigation.projectAppearance(
            projectId: project.projectId,
            vaultId: sidebarViewModel.currentVault?.id
        )
    }

    private func projectDisplayName(_ project: ProjectOverviewItem) -> String {
        project.projectDisplayName.nilIfBlank
            ?? project.projectName.split(separator: "/").last.map(String.init)
            ?? project.projectName
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
                to: .projects
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
        case .projects:
            return true
        case let .project(projectID):
            return sidebarViewModel.allProjectItems.contains(where: { $0.projectId == projectID })
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
        case .projects:
            mainWindowNavigation.showProjects()
        case .project:
            mainWindowNavigation.showProjects()
        }
        syncChatContext()
    }

    private func deleteProject(
        _ project: ProjectOverviewItem,
        meetingDisposition: ProjectMeetingDisposition,
        deletesSummaryFiles: Bool
    ) async -> String? {
        guard await sidebarViewModel.deleteProjectHierarchy(
            id: project.projectId,
            meetingDisposition: meetingDisposition,
            deletesSummaryFiles: deletesSummaryFiles
        ) else {
            return sidebarViewModel.lastError ?? L10n.projectOperationFailedDescription
        }
        dismissProjectEditor()
        return nil
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
