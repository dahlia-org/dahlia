import AppKit
import SwiftUI

enum WindowID {
    static let main = "main"
    static let vaultManager = "vault-manager"
    static let organizationWorkspace = "organization-workspace"
    static let audioRecognitionTest = "audio-recognition-test"
    static let applicationLogs = "application-logs"
    static let codexChat = "codex-chat"
    static let permissions = "permissions"
}

private enum MainWindowMetrics {
    static let defaultWidth: CGFloat = 1120
    static let defaultHeight: CGFloat = 740
}

@main
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
    private let mainWindowNavigation: MainWindowNavigation
    @State private var appDatabase: AppDatabaseManager?
    @State private var showVaultPicker = true

    @MainActor
    init() {
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
            meetingDetectionService: meetingDetectionService
        )
        let menuBarCalendarViewModel = MenuBarCalendarViewModel()
        let liveSubtitleOverlayCoordinator = LiveSubtitleOverlayCoordinator(
            viewModel: viewModel,
            liveSubtitleOverlayService: liveSubtitleOverlayService
        )
        let chatCoordinator = CodexChatCoordinator()
        chatCoordinator.liveModeStatusDidChange = { [weak viewModel] isEnabled in
            viewModel?.setChatLiveModeEnabled(isEnabled)
        }
        viewModel.finalizedLiveTranscriptHandler = { [weak chatCoordinator] text, wasTruncated in
            chatCoordinator?.receiveFinalizedLiveTranscript(text, wasTruncated: wasTruncated)
        }
        viewModel.chatLiveModeFailureHandler = { [weak chatCoordinator] in
            chatCoordinator?.disableLiveMode()
        }

        _viewModel = StateObject(wrappedValue: viewModel)
        _updateController = State(initialValue: updateController)
        _sidebarViewModel = State(initialValue: sidebarViewModel)
        _meetingDetectionService = StateObject(wrappedValue: meetingDetectionService)
        _liveSubtitleOverlayService = StateObject(wrappedValue: liveSubtitleOverlayService)
        _recordingCoordinator = State(initialValue: recordingCoordinator)
        _menuBarCalendarViewModel = State(initialValue: menuBarCalendarViewModel)
        _liveSubtitleOverlayCoordinator = State(initialValue: liveSubtitleOverlayCoordinator)
        _chatCoordinator = State(initialValue: chatCoordinator)
        self.mainWindowNavigation = mainWindowNavigation
    }

    var body: some Scene {
        Window(L10n.dahlia, id: WindowID.main) {
            Group {
                if mainWindowNavigation.isShowingSettings {
                    SettingsView(
                        captionViewModel: viewModel,
                        sidebarViewModel: sidebarViewModel,
                        mainWindowNavigation: mainWindowNavigation,
                        onSelectVault: { vault in openVault(vault) }
                    )
                } else if showVaultPicker {
                    VaultPickerView(
                        appDatabase: appDatabase,
                        canSwitchVault: viewModel.canSwitchVault
                    ) { vault in
                        openVault(vault)
                    }
                } else {
                    ContentView(
                        viewModel: viewModel,
                        updateController: updateController,
                        sidebarViewModel: sidebarViewModel,
                        recordingCoordinator: recordingCoordinator,
                        chatCoordinator: chatCoordinator,
                        mainWindowNavigation: mainWindowNavigation,
                        onSelectVault: { vault in openVault(vault) }
                    )
                }
            }
            .toolbar {
                if !mainWindowNavigation.isShowingSettings,
                   showVaultPicker,
                   updateController.isUpdateAvailable {
                    ToolbarItem(placement: .primaryAction) {
                        AppUpdateBadge(updateController: updateController)
                    }
                }
            }
            .task {
                _ = liveSubtitleOverlayCoordinator
                initializeAppIfNeeded()
                let settings = AppSettings.shared
                async let driveRestore: Void = GoogleDriveStore.shared.restoreSessionIfNeeded()
                await CalendarSourceCoordinator.shared.refreshEnabledSources(settings.enabledCalendarSources)
                await driveRestore
            }
            .modifier(MainWindowOpenWindowRegistrationModifier())
            .environment(mainWindowNavigation)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: MainWindowMetrics.defaultWidth, height: MainWindowMetrics.defaultHeight)
        .defaultLaunchBehavior(.presented)
        .commands {
            SettingsCommands(mainWindowNavigation: mainWindowNavigation)
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updateController.updater)
            }
            OrganizationWorkspaceCommands()
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
                    ContentUnavailableView(
                        L10n.chatWindowUnavailable,
                        systemImage: "bubble.left.and.bubble.right"
                    )
                }
            }
            .environment(mainWindowNavigation)
        }
        .defaultSize(width: 620, height: 720)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .dahliaSettingsCommands(mainWindowNavigation)

        Window(L10n.vault, id: WindowID.vaultManager) {
            VaultPickerView(
                appDatabase: appDatabase,
                canSwitchVault: viewModel.canSwitchVault
            ) { vault in
                openVault(vault)
            }
        }
        .windowStyle(.automatic)
        .dahliaSettingsCommands(mainWindowNavigation)

        Window(L10n.customerIntelligence, id: WindowID.organizationWorkspace) {
            OrganizationWorkspaceView(
                sidebarViewModel: sidebarViewModel,
                chatCoordinator: chatCoordinator,
                mainWindowNavigation: mainWindowNavigation
            )
        }
        .defaultSize(width: 1380, height: 820)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .dahliaSettingsCommands(mainWindowNavigation)

        Window(L10n.audioRecognitionTest, id: WindowID.audioRecognitionTest) {
            MicrophoneRecognitionTestView(captionViewModel: viewModel)
        }
        .defaultSize(width: 720, height: 700)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .dahliaSettingsCommands(mainWindowNavigation)

        Window(L10n.applicationLogs, id: WindowID.applicationLogs) {
            ApplicationLogView()
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .dahliaSettingsCommands(mainWindowNavigation)

        Window(L10n.permissions, id: WindowID.permissions) {
            PermissionGuideWindowView()
        }
        .defaultSize(width: 680, height: 620)
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

    private func initializeAppIfNeeded() {
        guard appDatabase == nil else { return }
        guard AppDelegate.hasMutationOwnership else { return }
        guard let db = try? AppDatabaseManager() else { return }
        appDatabase = db
        sidebarViewModel.setAppDatabase(db)
        viewModel.configureBatchTranscription(dbQueue: db.dbQueue) { [weak sidebarViewModel] in
            await sidebarViewModel?.refreshUnprocessedRecordings()
        }
        appDelegate.terminationHandler = { [weak viewModel] in
            await viewModel?.prepareForTermination()
        }

        let repo = MeetingRepository(dbQueue: db.dbQueue)
        if let lastVault = try? repo.fetchLastOpenedVault() {
            openVault(lastVault)
        }
        configureMeetingDetection(in: db)
    }

    private func openVault(_ vault: VaultRecord) {
        guard viewModel.canSwitchVault, let db = appDatabase else { return }

        try? FileManager.default.createDirectory(at: vault.url, withIntermediateDirectories: true)

        sidebarViewModel.clearMeetingSelection()
        viewModel.clearCurrentMeeting()
        mainWindowNavigation.changeVault(to: vault.id)
        AppSettings.shared.currentVault = vault
        chatCoordinator.activateVault(vault.id)
        sidebarViewModel.setAppDatabase(db)
        sidebarViewModel.updateVaultLastOpened(vault.id)
        viewModel.prepareAnalyzer()
        showVaultPicker = false
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
            onJoinAndStartRecording: { meeting in
                joinAndStartRecording(meeting, in: db)
            }
        )
        meetingDetectionService.start()
    }

    private func joinAndStartRecording(_ meeting: DetectedMeeting, in db: AppDatabaseManager) {
        handleDetectedMeeting(meeting, in: db, startTranscription: true)
        if let conferenceURI = meeting.calendarEvent?.conferenceURI {
            NSWorkspace.shared.open(conferenceURI)
        }
    }

    private func handleDetectedMeeting(
        _ meeting: DetectedMeeting,
        in db: AppDatabaseManager,
        startTranscription: Bool
    ) {
        guard let vault = AppSettings.shared.currentVault else { return }
        mainWindowNavigation.openMeetings()

        if let event = meeting.calendarEvent {
            let repository = MeetingRepository(dbQueue: db.dbQueue)
            do {
                if let existingMeetingId = try repository.resolveMeetingIdForCalendarEvent(
                    event,
                    vaultId: vault.id,
                    customerIntelligenceIngestion: startTranscription
                        ? .afterCaptureStarts
                        : .afterMeetingPersistence
                ) {
                    sidebarViewModel.selectMeeting(existingMeetingId)
                    if startTranscription {
                        startTranscriptionForMeeting(
                            existingMeetingId,
                            in: db,
                            vault: vault,
                            customerIntelligenceEvent: event
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
                vaultURL: vault.url
            )
            guard let meetingId = viewModel.materializeDraftMeeting(
                customerIntelligenceIngestion: startTranscription
                    ? .afterCaptureStarts
                    : .afterMeetingPersistence
            ) else { return }
            sidebarViewModel.selectMeeting(meetingId)
            if startTranscription {
                startTranscriptionForMeeting(
                    meetingId,
                    in: db,
                    vault: vault,
                    customerIntelligenceEvent: event
                )
            }
            return
        }

        viewModel.createEmptyMeeting(
            dbQueue: db.dbQueue,
            projectURL: nil,
            vaultId: vault.id,
            projectId: nil,
            name: "",
            projectName: nil,
            vaultURL: vault.url
        )
        guard let meetingId = viewModel.currentMeetingId else { return }
        sidebarViewModel.selectMeeting(meetingId)
        if startTranscription {
            startTranscriptionForMeeting(meetingId, in: db, vault: vault)
        }
    }

    private func startTranscriptionForMeeting(
        _ meetingId: UUID,
        in db: AppDatabaseManager,
        vault: VaultRecord,
        customerIntelligenceEvent: CalendarEvent? = nil
    ) {
        let ctx: (projectURL: URL?, projectId: UUID?, projectName: String?)
        do {
            ctx = try meetingContext(for: meetingId, in: db, vault: vault)
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
                vaultId: vault.id,
                projectId: ctx.projectId,
                projectName: ctx.projectName,
                vaultURL: vault.url,
                appendingTo: meetingId,
                reservation: reservation
            )
            recordingCoordinator.recordingDidStart()
            if let customerIntelligenceEvent,
               viewModel.isListening,
               viewModel.recordingMeetingId == meetingId {
                CustomerIntelligenceIngestionService.schedule(
                    calendarEvent: customerIntelligenceEvent,
                    meetingId: meetingId,
                    vaultId: vault.id,
                    observedAt: .now,
                    dbQueue: db.dbQueue
                )
            }
        }
    }

    private func meetingContext(
        for meetingId: UUID,
        in db: AppDatabaseManager,
        vault: VaultRecord
    ) throws -> (projectURL: URL?, projectId: UUID?, projectName: String?) {
        let repository = MeetingRepository(dbQueue: db.dbQueue)
        guard let meeting = try repository.fetchMeeting(id: meetingId) else {
            return (nil, nil, nil)
        }
        let project = try meeting.projectId.flatMap { try repository.fetchProject(id: $0) }
        let projectURL = project.map { vault.url.appending(path: $0.path, directoryHint: .isDirectory) }
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
    @MainActor private(set) static var backupRestoreOutcome: BackupRestoreStartupOutcome = .none
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

    private var isWaitingForCodexShutdown = false
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
            Self.backupRestoreOutcome = BackupRestoreStartupProcessor.applyPendingRestore()
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
        guard !isWaitingForCodexShutdown else { return .terminateLater }
        isWaitingForCodexShutdown = true
        Task {
            if let failureMessage = await terminationHandler?() {
                isWaitingForCodexShutdown = false
                sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.terminationPersistenceFailedTitle
                alert.informativeText = failureMessage
                alert.runModal()
                return
            }
            await CodexAppServerService.shared.shutdown()
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
