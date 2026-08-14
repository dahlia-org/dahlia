import DahliaRuntimeSupport
import SwiftUI

/// ミーティング一覧サイドバーと詳細ビューを構成するルートビュー。
struct ContentView: View {
    @ObservedObject var viewModel: CaptionViewModel
    var updateController: AppUpdateController
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator
    var chatCoordinator: CodexChatCoordinator
    var mainWindowNavigation: MainWindowNavigation
    var onSelectVault: (VaultRecord) -> Void = { _ in }

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

    var body: some View {
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
                        onShowUpcomingSchedule: returnToCalendarSchedule,
                        onShowUnprocessedRecordings: showUnprocessedRecordings,
                        showsCustomerIntelligence: isCustomerIntelligenceBetaEnabled,
                        onOpenCustomerIntelligence: { openWindow(id: WindowID.organizationWorkspace) },
                        onSelectVault: onSelectVault
                    )
                } else {
                    HSplitView {
                        if isSidebarVisible {
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
                                onSelectVault: onSelectVault
                            )
                            .mainSidebarPane(
                                width: mainWindowNavigation.sidebarWidth,
                                onWidthChange: mainWindowNavigation.updateSidebarWidth
                            )
                        }

                        detailView
                            .navigationTitle("")
                            .mainDetailPane()
                    }
                }
            }
            .layoutPriority(1)

            if chatCoordinator.isDockedVisible {
                CodexChatSidebarView(
                    coordinator: chatCoordinator,
                    sidebarViewModel: sidebarViewModel,
                    showsHistory: $isShowingChatHistory,
                    showsConfiguration: $isShowingChatConfiguration,
                    onOpenDetachedSession: openDetachedChat
                )
                .mainChatSidebarPane(
                    width: mainWindowNavigation.chatSidebarWidth,
                    onWidthChange: mainWindowNavigation.updateChatSidebarWidth
                )
            }
        }
        .toolbar(removing: .title)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            if !mainWindowNavigation.isShowingSettings {
                MainWindowNavigationToolbar(
                    isSidebarVisible: isSidebarVisible,
                    isChatSidebarVisible: chatCoordinator.isDockedVisible,
                    chatSidebarWidth: mainWindowNavigation.chatSidebarWidth,
                    chatSessionTitle: chatCoordinator.dockedSession.displayTitle,
                    isShowingChatHistory: isShowingChatHistory,
                    canGoBack: canGoBack,
                    canGoForward: canGoForward,
                    onToggleSidebar: toggleSidebar,
                    onSearch: showSearch,
                    onGoBack: goBack,
                    onGoForward: goForward,
                    onNewChat: startNewDockedChat,
                    onShowChatHistory: showChatHistory,
                    onHideChatHistory: hideChatHistory,
                    onPopOutChat: popOutDockedChat,
                    onToggleChat: toggleChat
                )
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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
        .overlay(alignment: .bottomTrailing) {
            if chatCoordinator.isDockedVisible {
                CodexChatConfigurationOverlay(
                    session: chatCoordinator.dockedSession,
                    isPresented: $isShowingChatConfiguration
                )
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
            }
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
            handleMeetingSelectionChange(newValue)
            if newValue.isEmpty {
                mainWindowNavigation.recordUpcomingScheduleIfVisible(isShowingUpcomingSchedule)
            }
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

    private func startNewDockedChat() {
        isShowingChatHistory = false
        dismissChatConfiguration()
        chatCoordinator.newDockedChat()
    }

    private func showChatHistory() {
        isShowingChatHistory = true
        Task { await chatCoordinator.refreshHistory() }
    }

    private func hideChatHistory() {
        isShowingChatHistory = false
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
                ? viewModel.currentMeetingId ?? sidebarViewModel.selectedMeetingId
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

    private var hasMeetingDetail: Bool { sidebarViewModel.selectedMeetingId != nil || viewModel.hasDraftMeeting || viewModel.currentMeetingId != nil }

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

    private func handleMeetingSelectionChange(_ selection: Set<UUID>) {
        guard selection.count == 1, let meetingId = selection.first else {
            if !selection.isEmpty || !viewModel.hasDraftMeeting {
                viewModel.clearCurrentMeeting()
            }
            return
        }
        handleMeetingSelection(meetingId)
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
           let meetingId = sidebarViewModel.selectedMeetingId,
           viewModel.currentMeetingId != meetingId {
            handleMeetingSelection(meetingId)
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
            let exists = await meetingExists(meetingID)
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

    private func meetingExists(_ meetingID: UUID) async -> Bool {
        guard let dbQueue = sidebarViewModel.dbQueue,
              let vaultID = sidebarViewModel.currentVault?.id else { return false }
        let existsInVault = await Task.detached(priority: .userInitiated) {
            try? MeetingRepository(dbQueue: dbQueue).fetchMeeting(id: meetingID)?.vaultId == vaultID
        }.value == true
        return existsInVault && sidebarViewModel.currentVault?.id == vaultID
    }

    private func handleMeetingSelection(_ meetingId: UUID) {
        guard let dbQueue = sidebarViewModel.dbQueue,
              let vault = sidebarViewModel.currentVault else { return }

        do {
            let repository = MeetingRepository(dbQueue: dbQueue)
            guard let meeting = try repository.fetchMeeting(id: meetingId) else { return }
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
