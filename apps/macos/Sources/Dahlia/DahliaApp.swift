import AppKit
import Combine
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

struct DahliaApp: App {
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
    @State private var imageBroker: DahliaImageBrokerServer?
    private let recordingActivityObservation: AnyCancellable
    private let mainWindowNavigation: MainWindowNavigation
    @State private var appDatabase: AppDatabaseManager?
    @State private var startup: AppStartupModel
    @State private var showWorkspacePicker = true

    @MainActor
    init() {
        AppSettings.shared.applyAppearance()
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
            onRecordingDidStart: {
                meetingDetectionService.recordingDidStart()
            },
            onRecordingDidStop: {
                meetingDetectionService.recordingDidStop()
            },
            isAppReady: { startup.isReady && !startup.isTerminating }
        )
        recordingActivityObservation = viewModel.recordingActivityPublisher.sink { active in
            AgentBackgroundActivity.setRecording(active)
            Task { await PiChatService.shared.drainLearningWork() }
        }
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
                        .environment(chatCoordinator)
                        .onReceive(NotificationCenter.default.publisher(for: AgentLearningSettings.sendChat)) { notification in
                            guard let prompt = notification.object as? String else { return }
                            mainWindowNavigation.dismissSettingsModal()
                            mainWindowNavigation.dismissSettings()
                            mainWindowNavigation.resetNavigationHistory(to: .chat)
                            chatCoordinator.sendInNewDockedChat(prompt)
                        }
                        .onReceive(NotificationCenter.default.publisher(for: AgentLearningSettings.openThread)) { notification in
                            guard let id = notification.object as? String else { return }
                            Task {
                                guard let thread = try? await PiChatService.shared.loadThread(id: id) else { return }
                                mainWindowNavigation.dismissSettingsModal()
                                mainWindowNavigation.dismissSettings()
                                mainWindowNavigation.resetNavigationHistory(to: .chat)
                                _ = await chatCoordinator.openHistoryThread(CodexChatThreadSummary(
                                    id: thread.id,
                                    title: thread.title,
                                    updatedAt: .now
                                ))
                            }
                        }
                    }
                }
                .disabled(mainWindowNavigation.settingsModal != nil)
                .accessibilityHidden(mainWindowNavigation.settingsModal != nil)

                if let settingsModal = mainWindowNavigation.settingsModal {
                    settingsModal
                }
            }
            .modifier(DatabricksSignOutPresentation())
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
            .sheet(item: $viewModel.pendingBatchTranscriptionConfirmation) { confirmation in
                BatchTranscriptionConfirmationView(
                    viewModel: viewModel,
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
                await startup.start(onReady: finishLaunching) {
                    try await initializeApp()
                }
            }
            .onChange(of: hasNoWorkspaces, initial: true) { _, hasNoWorkspaces in
                if hasNoWorkspaces, mainWindowNavigation.setupTourMode == nil {
                    mainWindowNavigation.presentInitialSetupTour()
                }
            }
            .onChange(of: dahliaAccountController.connections) {
                Task { await reconcileWorkspacesAfterAccountChange() }
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

    private var hasNoWorkspaces: Bool {
        workspaceManagementModel.hasLoadedWorkspaces && workspaceManagementModel.workspaces.isEmpty
    }

    private func finishLaunching() {
        guard let appDatabase else { return }
        configureMeetingDetection(in: appDatabase)
        let accountScopes = [AppAccountScope.local] + dahliaAccountController.connections.map { .dahlia($0.id) }
        Task.detached { GoogleSignInAdapter.deleteRetiredCredentials(scopes: accountScopes) }
        Task {
            await CalendarSourceCoordinator.shared.refreshEnabledSources(AppSettings.shared.enabledCalendarSources)
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
        AccountsDatabase.configure(db.dbQueue)
        // Account consumers require the completed migration. A failure blocks launch and retries next time.
        try await SingleAccountMigration.runAtLaunch(dbQueue: db.dbQueue)
        CalendarAutoRecordingStore.shared.activateAfterAccountMigration()
        await GoogleProviderAccountsModel.shared.activate()
        await CalendarProviderCollection.shared.activateAfterAccountMigration()
        DatabricksOAuthStorage.removeLegacyConnections()
        // Accounts are in the database now; listeners such as the Google Calendar proxy re-read them.
        NotificationCenter.default.post(name: .databricksConnectionDidChange, object: nil)
        CalendarSourceCoordinator.shared.configure(dbQueue: db.dbQueue)
        try? await ScreenshotStorageMaintenance.compactAtStartup(dbQueue: db.dbQueue)
        appDatabase = db
        let workspaceAISettings = WorkspaceAISettingsModel.shared
        workspaceAISettings.configure(dbQueue: db.dbQueue)
        do {
            try await PiChatService.shared.configureHistory(dbQueue: db.dbQueue)
        } catch {
            ErrorReportingService.capture(error, context: ["source": "chatHistoryStartup"])
        }
        await Housekeeping.shared.start([
            .init(name: "agentLearning", everyTicks: 1) { await PiChatService.shared.drainLearningWork() },
            .init(name: "skillCurator", everyTicks: 60, firstTick: 2) { await PiChatService.shared.maybeRunCurator() },
            .init(name: "systemRunRetention", everyTicks: 24 * 60, firstTick: 2) { await PiChatService.shared.pruneSystemRuns() },
            .init(name: "alwaysOn", everyTicks: 1, firstTick: 1) { await PiChatService.shared.drainAlwaysOn() },
        ])
        await PiChatService.shared.configureBackup(dbQueue: db.dbQueue)
        await ScreenshotContentProvider.shared.configure(dbQueue: db.dbQueue)
        await PiRuntimeContextCoordinator.shared.configure(dbQueue: db.dbQueue)
        do {
            try await workspaceAISettings.inheritLocalAccountSettings(from: db.dbQueue)
            try await MeetingRepository(dbQueue: db.dbQueue)
                .backfillWorkspaceAISettings(WorkspaceAISettingsLegacyValues(settings: .shared))
            try await workspaceAISettings.inheritAccountInferenceSettings(from: db.dbQueue)
        } catch {
            ErrorReportingService.capture(error, context: ["source": "workspaceAISettingsBackfill"])
        }
        await DahliaCloudCredentialStorage.deleteLegacyCredential()
        await dahliaAccountController.configure(appDatabase: db)
        do {
            let imageBroker = DahliaImageBrokerServer(dbQueue: db.dbQueue)
            try imageBroker.start()
            self.imageBroker = imageBroker
        } catch {
            ErrorReportingService.capture(error, context: ["source": "dahliaImageBroker"])
        }
        await db.searchIndexer.start()
        sidebarViewModel.setAppDatabase(db)
        viewModel.configureBatchTranscription(dbQueue: db.dbQueue) { [weak sidebarViewModel] in
            await sidebarViewModel?.refreshUnprocessedRecordings()
        }
        appDelegate.terminationHandler = { [weak viewModel, weak db, weak imageBroker] in
            imageBroker?.stop()
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
        chatCoordinator.activateWorkspace(workspace)
        sidebarViewModel.setAppDatabase(db)
        if recordsLastOpened {
            Task { await workspaceManagementModel.markWorkspaceOpened(workspace) }
        }
        viewModel.prepareAnalyzer()
        showWorkspacePicker = false
        return true
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

    private func completeSetupTour(_ workspace: WorkspaceRecord) async -> Bool {
        guard openWorkspace(workspace, recordsLastOpened: false),
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
        guard let event = meeting.calendarEvent else {
            handleDetectedMeeting(meeting, in: db, startTranscription: true)
            return
        }
        recordingCoordinator.openMeetingLink(for: event) {
            handleDetectedMeeting(meeting, in: db, startTranscription: true)
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
                    if startTranscription {
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
        let project = try meeting.projectId.flatMap {
            try repository.fetchProject(id: $0)
        }
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
            ApplicationLogFile.shared.start()
            let info = Bundle.main.infoDictionary ?? [:]
            AppLogger(category: "App").notice(
                "Dahlia launched version=\(info["CFBundleShortVersionString"] ?? "unknown") " +
                    "build=\(info["CFBundleVersion"] ?? "unknown") pid=\(ProcessInfo.processInfo.processIdentifier) " +
                    "os=\(ProcessInfo.processInfo.operatingSystemVersionString)"
            )
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
        MainActorHangMonitor.shared.start()
        UsageTelemetryService.shared.start()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            do {
                try await DocumentEditorModel.finishLocalSaves()
            } catch {
                isTerminating = false
                sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.terminationPersistenceFailedTitle
                alert.informativeText = L10n.documentSaveFailed
                alert.runModal()
                return
            }
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
            await PiRuntimeService.shared.shutdown()
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
