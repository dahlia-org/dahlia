import AppKit
import SwiftUI

enum WindowID {
    static let main = "main"
    static let audioRecognitionTest = "audio-recognition-test"
    static let applicationLogs = "application-logs"
    static let codexChat = "codex-chat"
}

private enum MainWindowMetrics {
    static let minimumWidth: CGFloat = 720
    static let minimumHeight: CGFloat = 520
    static let defaultWidth: CGFloat = 1120
    static let defaultHeight: CGFloat = 740
}

@main
struct DahliaApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var updateController: AppUpdateController
    @StateObject private var viewModel: CaptionViewModel
    @State private var sidebarViewModel: SidebarViewModel
    @StateObject private var meetingDetectionService: MeetingDetectionService
    @StateObject private var liveSubtitleOverlayService: LiveSubtitleOverlayService
    @State private var liveSubtitleOverlayCoordinator: LiveSubtitleOverlayCoordinator
    @State private var recordingCoordinator: RecordingCoordinator
    @State private var menuBarCalendarViewModel: MenuBarCalendarViewModel
    @State private var chatCoordinator: CodexChatCoordinator
    @State private var workspaceManagementModel: WorkspaceManagementModel
    @State private var dahliaAccountController = DahliaCloudAccountController.shared
    @State private var tokenBroker = DahliaTokenBrokerServer()
    @State private var imageBroker: DahliaImageBrokerServer?
    private let mainWindowNavigation: MainWindowNavigation
    @State private var appDatabase: AppDatabaseManager?
    @State private var meetingSyncWorker: SyncWorker?
    @State private var startup: AppStartupModel
    @State private var showWorkspacePicker = true
    @State private var pendingSetupAdoptionWorkspaceID: UUID?

    @MainActor
    init() {
        let startup = AppStartupModel()
        _startup = State(initialValue: startup)
        let updateController = AppUpdateController()
        let viewModel = CaptionViewModel()
        let sidebarViewModel = SidebarViewModel()
        let liveSubtitleOverlayService = LiveSubtitleOverlayService()
        let mainWindowNavigation = MainWindowNavigation.shared
        let meetingDetectionService = MeetingDetectionService()
        let recordingCoordinator = RecordingCoordinator(
            viewModel: viewModel,
            sidebarViewModel: sidebarViewModel,
            mainWindowNavigation: mainWindowNavigation,
            onRecordingDidStart: meetingDetectionService.recordingDidStart,
            onRecordingDidStop: meetingDetectionService.recordingDidStop,
            isAppReady: { startup.isReady && !startup.isTerminating }
        )
        let menuBarCalendarViewModel = MenuBarCalendarViewModel()
        let liveSubtitleOverlayCoordinator = LiveSubtitleOverlayCoordinator(
            viewModel: viewModel,
            liveSubtitleOverlayService: liveSubtitleOverlayService
        )
        let chatCoordinator = CodexChatCoordinator()
        _viewModel = StateObject(wrappedValue: viewModel)
        _updateController = State(initialValue: updateController)
        _sidebarViewModel = State(initialValue: sidebarViewModel)
        _meetingDetectionService = StateObject(wrappedValue: meetingDetectionService)
        _liveSubtitleOverlayService = StateObject(wrappedValue: liveSubtitleOverlayService)
        _recordingCoordinator = State(initialValue: recordingCoordinator)
        _menuBarCalendarViewModel = State(initialValue: menuBarCalendarViewModel)
        _liveSubtitleOverlayCoordinator = State(initialValue: liveSubtitleOverlayCoordinator)
        _chatCoordinator = State(initialValue: chatCoordinator)
        _workspaceManagementModel = State(initialValue: WorkspaceManagementModel())
        self.mainWindowNavigation = mainWindowNavigation
    }

    var body: some Scene {
        Window(L10n.dahlia, id: WindowID.main) {
            ZStack {
                Group {
                    if !startup.isReady {
                        AppStartupView(
                            state: startup.state,
                            onContinue: startup.continueAfterWarning,
                            onQuit: { NSApplication.shared.terminate(nil) }
                        )
                    } else if let setupTourMode = mainWindowNavigation.setupTourMode {
                        SetupTourView(
                            mode: setupTourMode,
                            currentWorkspace: AppSettings.shared.currentWorkspace,
                            workspaceManagementModel: workspaceManagementModel,
                            accountController: dahliaAccountController,
                            canComplete: { viewModel.canSwitchWorkspace },
                            onComplete: completeSetupTour
                        )
                    } else if showWorkspacePicker {
                        WorkspacePickerView(
                            appDatabase: appDatabase,
                            model: workspaceManagementModel,
                            canSwitchWorkspace: viewModel.canSwitchWorkspace,
                            captionViewModel: viewModel,
                            sidebarViewModel: sidebarViewModel,
                            mainWindowNavigation: mainWindowNavigation,
                            updateController: updateController
                        ) { workspace in
                            openWorkspace(workspace)
                        }
                    } else {
                        ContentView(
                            viewModel: viewModel,
                            updateController: updateController,
                            sidebarViewModel: sidebarViewModel,
                            recordingCoordinator: recordingCoordinator,
                            chatCoordinator: chatCoordinator,
                            mainWindowNavigation: mainWindowNavigation,
                            appDatabase: appDatabase,
                            workspaceManagementModel: workspaceManagementModel,
                            onSelectWorkspace: { workspace in openWorkspace(workspace) }
                        )
                    }
                }
                .disabled(mainWindowNavigation.isShowingDahliaSignIn)
                .accessibilityHidden(mainWindowNavigation.isShowingDahliaSignIn)

                if mainWindowNavigation.isShowingDahliaSignIn {
                    DahliaServerSignInView(
                        cloudConfiguration: dahliaAccountController.defaultConfiguration,
                        allowsCloudSignIn: dahliaAccountController.cloudConnection == nil,
                        isBusy: dahliaAccountController.isBusy,
                        isSigningIn: dahliaAccountController.isSigningIn,
                        errorMessage: dahliaAccountController.errorMessage,
                        onCancel: cancelDahliaSignIn,
                        onSignIn: signInToDahlia
                    )
                }
            }
            .dahliaAppearance()
            .frame(
                minWidth: MainWindowMetrics.minimumWidth,
                minHeight: MainWindowMetrics.minimumHeight
            )
            .dahliaSimpleWindowStyle()
            .alert(
                L10n.workspaceOperationFailed,
                isPresented: Binding(
                    get: { workspaceManagementModel.isShowingError },
                    set: { workspaceManagementModel.isShowingError = $0 }
                )
            ) {} message: {
                Text(workspaceManagementModel.errorMessage)
            }
            .overlay {
                if let pending = workspaceManagementModel.pendingServerAdoption {
                    WorkspaceImportView(
                        pending: pending, isBusy: workspaceManagementModel.updatingWorkspaceAccountID != nil,
                        onCancel: cancelServerAdoption,
                        onReload: { await workspaceManagementModel.reloadServerAdoption() },
                        onCreateOrganization: { await workspaceManagementModel.createAdoptionOrganization(name: $0) },
                        onImport: { destinationId, organizationId in
                            await confirmServerAdoption(pending, destinationId: destinationId, organizationId: organizationId)
                        }
                    )
                }
            }
            .confirmationDialog(
                dahliaAccountController.pendingSignOutConnection.map {
                    L10n.signOutDahliaConnection($0.displayName)
                } ?? "",
                isPresented: Binding(
                    get: { dahliaAccountController.pendingSignOutConnection != nil },
                    set: { if !$0 { dahliaAccountController.cancelSignOut() } }
                ),
                titleVisibility: .visible
            ) {
                Button(L10n.moveWorkspacesToLocalAndSignOut) {
                    dahliaAccountController.confirmSignOut(disposition: .moveToLocalAccount)
                }
                Button(L10n.deleteLocalWorkspacesAndSignOut, role: .destructive) {
                    dahliaAccountController.confirmSignOut(disposition: .deleteLocalCopies)
                }
                Button(L10n.cancel, role: .cancel) {
                    dahliaAccountController.cancelSignOut()
                }
            } message: {
                Text(L10n.signOutWorkspaceDispositionDescription)
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
                    allowsRecordedLanguageSelection: confirmation.allowsRecordedLanguageSelection,
                    initiallyGeneratesSummary: confirmation.initiallyGeneratesSummary,
                    summaryGenerationOptions: confirmation.summaryGenerationOptions,
                    isRetranscription: confirmation.isRetranscription,
                    processingMethod: confirmation.processingMethod,
                    onStart: { languageSelection, generatesSummary, summaryOptions, projectId in
                        if let error = viewModel.assignPendingBatchTranscriptionProject(projectId) {
                            return error
                        }
                        viewModel.confirmBatchTranscription(
                            languageSelection: languageSelection,
                            generatesSummary: generatesSummary,
                            summaryGenerationOptions: summaryOptions
                        )
                        return nil
                    },
                    onPostpone: viewModel.postponeBatchTranscription
                )
                .interactiveDismissDisabled()
            }
            .task {
                _ = liveSubtitleOverlayCoordinator
                guard !appDelegate.isTerminating else { return }
                appDelegate.startup = startup
                await startup.start(onReady: finishLaunching) { try await initializeApp() }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, let meetingSyncWorker else { return }
                ServerAccountSettingsModel.shared.refreshAll()
                Task { await meetingSyncWorker.applicationBecameActive() }
            }
            .onChange(of: dahliaAccountController.connections) {
                ServerAccountSettingsModel.shared.updateConnections(dahliaAccountController.connections)
                Task {
                    await reconcileWorkspacesAfterAccountChange()
                    await meetingSyncWorker?.applicationBecameActive()
                }
            }
            .modifier(MainWindowOpenWindowRegistrationModifier())
            .environment(mainWindowNavigation)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: MainWindowMetrics.defaultWidth, height: MainWindowMetrics.defaultHeight)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.createNewMeeting, action: recordingCoordinator.createEmptyMeeting)
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(
                        !startup.isReady
                            || showWorkspacePicker
                            || mainWindowNavigation.isShowingSettings
                            || mainWindowNavigation.isShowingDahliaSignIn
                            || !sidebarViewModel.canEditCurrentWorkspace
                    )
            }
            SettingsCommands(mainWindowNavigation: mainWindowNavigation)
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updateController.updater)
            }
        }

        WindowGroup(L10n.chat, id: WindowID.codexChat, for: CodexChatSessionID.self) { $sessionID in
            Group {
                if let sessionID {
                    CodexChatWindowView(
                        coordinator: chatCoordinator,
                        sidebarViewModel: sidebarViewModel,
                        sessionID: sessionID
                    )
                } else {
                    VStack(spacing: 0) {
                        DahliaWindowHeader(reservesWindowControls: true) {
                            Spacer()
                        }
                        ContentUnavailableView(
                            L10n.chatWindowUnavailable,
                            systemImage: "bubble.left.and.bubble.right"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .environment(mainWindowNavigation)
            .dahliaAppearance()
            .dahliaSimpleWindowStyle()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 620, height: 720)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .dahliaSettingsCommands(mainWindowNavigation)

        Window(L10n.audioRecognitionTest, id: WindowID.audioRecognitionTest) {
            VStack(spacing: 0) {
                DahliaWindowHeader(reservesWindowControls: true) {
                    Spacer()
                }
                MicrophoneRecognitionTestView(captionViewModel: viewModel)
            }
            .dahliaAppearance()
            .dahliaSimpleWindowStyle()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 700)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .dahliaSettingsCommands(mainWindowNavigation)

        Window(L10n.applicationLogs, id: WindowID.applicationLogs) {
            ApplicationLogView()
                .dahliaAppearance()
                .dahliaSimpleWindowStyle()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .dahliaSettingsCommands(mainWindowNavigation)

        MenuBarExtra {
            MenuBarMenuView(
                viewModel: viewModel,
                recordingCoordinator: recordingCoordinator,
                calendarViewModel: menuBarCalendarViewModel,
                mainWindowNavigation: mainWindowNavigation
            )
        } label: {
            MenuBarLabel(
                viewModel: viewModel,
                calendarViewModel: menuBarCalendarViewModel
            )
        }
        .menuBarExtraStyle(.menu)
    }

    private func finishLaunching() {
        guard let appDatabase else { return }
        configureMeetingDetection(in: appDatabase)
        Task {
            let settings = AppSettings.shared
            async let driveRestore: Void = GoogleDriveStore.shared.restoreSessionIfNeeded()
            await CalendarSourceCoordinator.shared.refreshEnabledSources(settings.enabledCalendarSources)
            await driveRestore
        }
    }

    private func initializeApp() async throws -> String? {
        guard AppDelegate.hasMutationOwnership else {
            throw CocoaError(.fileLocking)
        }
        let (db, restoreOutcome) = try await AppStartupModel.prepareDatabase { phase in
            startup.show(phase)
        }
        AppDelegate.backupRestoreOutcome = restoreOutcome
        startup.show(.loadingWorkspaces)
        CalendarSourceCoordinator.shared.configure(dbQueue: db.dbQueue)
        try? await ScreenshotStorageMaintenance.compactAtStartup(dbQueue: db.dbQueue)
        appDatabase = db
        let workspaceAISettings = WorkspaceAISettingsModel.shared
        workspaceAISettings.configure(dbQueue: db.dbQueue)
        await ScreenshotContentProvider.shared.configure(dbQueue: db.dbQueue)
        await CodexRuntimeContextCoordinator.shared.configure(dbQueue: db.dbQueue)
        do {
            try await MeetingRepository(dbQueue: db.dbQueue)
                .backfillWorkspaceAISettings(WorkspaceAISettingsLegacyValues(settings: .shared))
            try await workspaceAISettings.inheritLocalAccountSettings(from: db.dbQueue)
        } catch {
            ErrorReportingService.capture(error, context: ["source": "workspaceAISettingsBackfill"])
        }
        await DahliaCloudCredentialStorage.deleteLegacyCredential()
        await dahliaAccountController.configure(appDatabase: db)
        ServerAccountSettingsModel.shared.startNetworkMonitoring()
        ServerAccountSettingsModel.shared.updateConnections(dahliaAccountController.connections)
        let meetingSyncWorker = SyncWorker(dbQueue: db.dbQueue) {
            await reconcileWorkspacesAfterAccountChange()
            await dahliaAccountController.reload()
        }
        self.meetingSyncWorker = meetingSyncWorker
        dahliaAccountController.syncWorker = meetingSyncWorker
        // Backup restore only changes local workspaces; existing canonical sync resumes normally.
        await meetingSyncWorker.start()
        do {
            try tokenBroker.start()
            let imageBroker = DahliaImageBrokerServer(dbQueue: db.dbQueue)
            try imageBroker.start()
            self.imageBroker = imageBroker
        } catch {
            ErrorReportingService.capture(error, context: ["source": "dahliaTokenBroker"])
        }
        await db.searchIndexer.start()
        sidebarViewModel.setAppDatabase(db)
        viewModel.configureSearchIndexer(db.searchIndexer)
        viewModel.configureBatchTranscription(dbQueue: db.dbQueue) { [weak sidebarViewModel] in
            await sidebarViewModel?.refreshUnprocessedRecordings()
        }
        appDelegate.terminationHandler = { [weak viewModel, weak db, weak tokenBroker, weak imageBroker, weak meetingSyncWorker] in
            tokenBroker?.stop()
            imageBroker?.stop()
            await meetingSyncWorker?.stop()
            await db?.searchIndexer.stop()
            return await viewModel?.prepareForTermination()
        }

        let warning = AppStartupModel.restoreWarning(restoreOutcome)
        guard startup.beginWorkspaceLoading() else { return warning }
        await workspaceManagementModel.configure(appDatabase: db)
        guard !Task.isCancelled else { return warning }
        let setupVersion = UserDefaults.standard.integer(forKey: SetupTourPresentationPolicy.userDefaultsKey)
        let setupProgressExists = setupVersion < SetupTourPresentationPolicy.currentVersion
            && SetupTourPresentationPolicy.hasSavedProgress()
        if !setupProgressExists,
           let workspace = await workspaceManagementModel.resolveExistingStartupWorkspace(appDatabase: db) {
            guard !Task.isCancelled else { return warning }
            openWorkspace(workspace)
        } else if SetupTourPresentationPolicy.shouldPresentAutomatically(
            storedVersion: setupVersion,
            hasLoadedWorkspaces: workspaceManagementModel.hasLoadedWorkspaces,
            hasRegisteredWorkspaces: !workspaceManagementModel.workspaces.isEmpty,
            hasSavedProgress: setupProgressExists
        ), !Task.isCancelled {
            mainWindowNavigation.presentInitialSetupTour()
        }
        return warning
    }

    @discardableResult
    private func openWorkspace(_ workspace: WorkspaceRecord, recordsLastOpened: Bool = true) -> Bool {
        if !showWorkspacePicker, AppSettings.shared.currentWorkspace?.id == workspace.id {
            AppSettings.shared.currentWorkspace = workspace
            WorkspaceAISettingsModel.shared.activate(workspace: workspace)
            return true
        }
        guard viewModel.canSwitchWorkspace, let db = appDatabase else { return false }

        if let url = workspace.url {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        sidebarViewModel.clearMeetingSelection()
        viewModel.clearCurrentMeeting()
        mainWindowNavigation.changeWorkspace(to: workspace.id)
        AppSettings.shared.currentWorkspace = workspace
        WorkspaceAISettingsModel.shared.activate(workspace: workspace)
        chatCoordinator.activateWorkspace(workspace.id)
        sidebarViewModel.setAppDatabase(db)
        if recordsLastOpened {
            Task { await workspaceManagementModel.markWorkspaceOpened(workspace) }
        }
        viewModel.prepareAnalyzer()
        showWorkspacePicker = false
        return true
    }

    private func signInToDahlia(_ configuration: DahliaCloudConfiguration) {
        guard let task = dahliaAccountController.startSignIn(configuration: configuration) else { return }
        Task { @MainActor in
            await task.value
            if dahliaAccountController.errorMessage == nil,
               dahliaAccountController.completedSignInConnection(matching: configuration) != nil {
                mainWindowNavigation.dismissDahliaSignIn()
            }
        }
    }

    private func cancelDahliaSignIn() {
        dahliaAccountController.cancelAccountTask()
        mainWindowNavigation.dismissDahliaSignIn()
    }

    private func confirmServerAdoption(_ pending: PendingWorkspaceServerAdoption, destinationId: UUID?, organizationId: UUID?) async {
        guard let updated = await workspaceManagementModel.confirmServerAdoption(
            pending,
            destinationId: destinationId,
            organizationId: organizationId
        )
        else {
            if workspaceManagementModel.pendingServerAdoption == nil {
                pendingSetupAdoptionWorkspaceID = nil
            }
            return
        }
        await meetingSyncWorker?.drain()
        if pendingSetupAdoptionWorkspaceID == updated.id {
            pendingSetupAdoptionWorkspaceID = nil
            guard openWorkspace(updated, recordsLastOpened: false),
                  await workspaceManagementModel.markWorkspaceOpened(updated)
            else { return }
            SetupTourPresentationPolicy.markCompleted()
            mainWindowNavigation.completeSetupTour()
            await dahliaAccountController.reload()
            return
        }
        if AppSettings.shared.currentWorkspace?.id == updated.id {
            AppSettings.shared.currentWorkspace = updated
            WorkspaceAISettingsModel.shared.activate(workspace: updated)
        }
        await dahliaAccountController.reload()
    }

    private func cancelServerAdoption() {
        pendingSetupAdoptionWorkspaceID = nil
        workspaceManagementModel.cancelServerAdoption()
    }

    private func reconcileWorkspacesAfterAccountChange() async {
        await workspaceManagementModel.loadWorkspaces()
        guard let current = AppSettings.shared.currentWorkspace else { return }
        guard let updated = workspaceManagementModel.workspaces.first(where: { $0.id == current.id }) else {
            AppSettings.shared.currentWorkspace = nil
            sidebarViewModel.clearMeetingSelection()
            viewModel.clearCurrentMeeting()
            showWorkspacePicker = true
            return
        }
        AppSettings.shared.currentWorkspace = updated
        WorkspaceAISettingsModel.shared.activate(workspace: updated)
    }

    private func completeSetupTour(_ workspace: WorkspaceRecord, accountConnectionID: UUID?) async -> Bool {
        if let accountConnectionID, workspace.accountConnectionId == nil {
            guard let connection = dahliaAccountController.connections.first(where: {
                $0.id == accountConnectionID
            }) else { return false }
            await workspaceManagementModel.requestServerAdoption(for: workspace, connection: connection)
            guard workspaceManagementModel.pendingServerAdoption?.workspace.id == workspace.id else { return false }
            pendingSetupAdoptionWorkspaceID = workspace.id
            return true
        }
        guard workspace.accountConnectionId == accountConnectionID,
              openWorkspace(workspace, recordsLastOpened: false),
              await workspaceManagementModel.markWorkspaceOpened(workspace)
        else { return false }
        await dahliaAccountController.reload()
        SetupTourPresentationPolicy.markCompleted()
        mainWindowNavigation.completeSetupTour()
        return true
    }

    private func configureMeetingDetection(in db: AppDatabaseManager) {
        meetingDetectionService.isRecording = { [weak viewModel] in
            viewModel?.isRecordingLifecycleBusy ?? false
        }
        meetingDetectionService.isActivelyRecording = { [weak viewModel] in
            viewModel?.isListening ?? false
        }
        meetingDetectionService.onAutomaticRecording = { [weak recordingCoordinator] event in
            recordingCoordinator?.startAutomaticRecording(forCalendarEvent: event)
        }
        meetingDetectionService.onAutomaticRecordingStop = { [weak recordingCoordinator] in
            recordingCoordinator?.stopRecording()
        }
        MeetingNotificationService.shared.configure(
            onOpenMeeting: { meeting in
                handleDetectedMeeting(meeting, in: db, startTranscription: false)
            },
            onStartRecording: { meeting in
                handleDetectedMeeting(meeting, in: db, startTranscription: true)
            },
            onJoinMeeting: { [weak recordingCoordinator] meeting in
                guard let event = meeting.calendarEvent else { return }
                recordingCoordinator?.openMeetingLink(for: event)
            },
            onJoinAndStartRecording: { meeting in
                joinAndStartRecording(meeting, in: db)
            }
        )
        meetingDetectionService.start()
    }

    private func joinAndStartRecording(_ meeting: DetectedMeeting, in db: AppDatabaseManager) {
        handleDetectedMeeting(meeting, in: db, startTranscription: true)
        if let event = meeting.calendarEvent {
            recordingCoordinator.openMeetingLink(for: event)
        }
    }

    private func handleDetectedMeeting(
        _ meeting: DetectedMeeting,
        in db: AppDatabaseManager,
        startTranscription: Bool
    ) {
        guard startup.isReady, !startup.isTerminating,
              let workspace = AppSettings.shared.currentWorkspace else { return }
        mainWindowNavigation.openMeetings()

        if let event = meeting.calendarEvent {
            let repository = MeetingRepository(dbQueue: db.dbQueue)
            do {
                if let existingMeetingId = try repository.resolveMeetingIdForCalendarEvent(
                    event,
                    workspaceId: workspace.id
                ) {
                    sidebarViewModel.selectMeeting(existingMeetingId)
                    if startTranscription, workspace.allowsCanonicalEdits {
                        startTranscriptionForMeeting(
                            existingMeetingId,
                            in: db,
                            workspace: workspace
                        )
                    }
                    return
                }
            } catch {
                viewModel.errorMessage = error.localizedDescription
                ErrorReportingService.capture(error, context: ["source": "calendarMeetingResolution"])
                return
            }

            guard workspace.allowsCanonicalEdits else { return }
            sidebarViewModel.clearMeetingSelection()
            viewModel.beginDraftMeeting(
                from: event,
                dbQueue: db.dbQueue,
                workspaceURL: workspace.url
            )
            guard let meetingId = viewModel.materializeDraftMeeting() else { return }
            sidebarViewModel.selectMeeting(meetingId)
            if startTranscription {
                startTranscriptionForMeeting(
                    meetingId,
                    in: db,
                    workspace: workspace
                )
            }
            return
        }

        guard workspace.allowsCanonicalEdits else { return }
        guard let meetingId = viewModel.createEmptyMeeting(
            dbQueue: db.dbQueue,
            projectURL: nil,
            workspaceId: workspace.id,
            projectId: nil,
            name: "",
            projectName: nil,
            workspaceURL: workspace.url
        ) else { return }
        sidebarViewModel.selectMeeting(meetingId)
        if startTranscription {
            startTranscriptionForMeeting(meetingId, in: db, workspace: workspace)
        }
    }

    private func startTranscriptionForMeeting(
        _ meetingId: UUID,
        in db: AppDatabaseManager,
        workspace: WorkspaceRecord
    ) {
        let ctx: (projectURL: URL?, projectId: UUID?, projectName: String?)
        do {
            ctx = try meetingContext(for: meetingId, in: db, workspace: workspace)
        } catch {
            viewModel.errorMessage = error.localizedDescription
            ErrorReportingService.capture(error, context: ["source": "meetingContext"])
            return
        }
        guard let reservation = viewModel.reserveRecordingStart() else { return }
        Task { @MainActor in
            await viewModel.startListening(
                dbQueue: db.dbQueue,
                projectURL: ctx.projectURL,
                workspaceId: workspace.id,
                projectId: ctx.projectId,
                projectName: ctx.projectName,
                workspaceURL: workspace.url,
                appendingTo: meetingId,
                reservation: reservation
            )
            recordingCoordinator.recordingDidStart()
        }
    }

    private func meetingContext(
        for meetingId: UUID,
        in db: AppDatabaseManager,
        workspace: WorkspaceRecord
    ) throws -> (projectURL: URL?, projectId: UUID?, projectName: String?) {
        let repository = MeetingRepository(dbQueue: db.dbQueue)
        guard let meeting = try repository.fetchMeeting(id: meetingId) else {
            return (nil, nil, nil)
        }
        let project = try meeting.projectId.flatMap { try repository.fetchProject(id: $0) }
        let projectURL = project.flatMap { project in
            workspace.url?.appending(path: project.path, directoryHint: .isDirectory)
        }
        return (projectURL, project?.id, project?.path)
    }
}

private struct MainWindowOpenWindowRegistrationModifier: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            MainWindowOpener.shared.register(openWindow: openWindow)
        }
    }
}

private extension Scene {
    func dahliaSettingsCommands(_ navigation: MainWindowNavigation) -> some Scene {
        commands {
            SettingsCommands(mainWindowNavigation: navigation)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private(set) static var hasMutationOwnership = false
    @MainActor static var backupRestoreOutcome: BackupRestoreStartupOutcome = .none
    @MainActor private(set) static var isBackupRestorePreparationActive = false

    @MainActor
    static func beginBackupRestorePreparation() -> Bool {
        guard !isBackupRestorePreparationActive else { return false }
        isBackupRestorePreparationActive = true
        return true
    }

    @MainActor
    static func cancelBackupRestorePreparation() {
        isBackupRestorePreparationActive = false
    }

    @MainActor var startup: AppStartupModel?
    @MainActor private(set) var isTerminating = false
    private var processLock: AdvisoryFileLock?
    @MainActor var terminationHandler: (@MainActor () async -> String?)?

    func applicationWillFinishLaunching(_: Notification) {
        do {
            processLock = try AdvisoryFileLock.acquire(
                at: AppDatabaseManager.databaseURL
                    .deletingLastPathComponent()
                    .appending(path: ".process.lock")
            )
            Self.hasMutationOwnership = true
        } catch AdvisoryFileLockError.alreadyLocked {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.anotherDahliaInstanceTitle
            alert.informativeText = L10n.anotherDahliaInstanceMessage
            alert.runModal()
            NSApplication.shared.terminate(nil)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        guard Self.hasMutationOwnership else { return }
        MeetingNotificationService.shared.install()
        ErrorReportingService.start()
        UsageTelemetryService.shared.start()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task {
            // Connection errors are surfaced by the AI settings and summary actions.
            try? await CodexAppServerService.shared.start()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            await startup?.prepareForTermination()
            if let failureMessage = await terminationHandler?() {
                isTerminating = false
                startup?.cancelTermination()
                sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.terminationPersistenceFailedTitle
                alert.informativeText = failureMessage
                alert.runModal()
                return
            }
            await CodexAppServerService.shared.shutdown()
            await CodexAppServerService.macInference.shutdown()
            await CodexAppServerService.localAccount.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainWindowOpener.shared.openMainWindow()
        }
        return true
    }
}
