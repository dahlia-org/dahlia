import AppKit
import SwiftUI

enum WindowID {
    static let main = "main"
    static let vaultManager = "vault-manager"
    static let projectManager = "project-manager"
    static let audioRecognitionTest = "audio-recognition-test"
    static let applicationLogs = "application-logs"
    static let codexChat = "codex-chat"
}

private enum MainWindowMetrics {
    static let defaultWidth: CGFloat = 1120
    static let defaultHeight: CGFloat = 740
}

@main
struct DahliaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel: CaptionViewModel
    @State private var sidebarViewModel: SidebarViewModel
    @StateObject private var meetingDetectionService = MeetingDetectionService()
    @StateObject private var liveSubtitleOverlayService: LiveSubtitleOverlayService
    @State private var liveSubtitleOverlayCoordinator: LiveSubtitleOverlayCoordinator
    @State private var recordingCoordinator: RecordingCoordinator
    @State private var menuBarCalendarViewModel: MenuBarCalendarViewModel
    @State private var chatCoordinator: CodexChatCoordinator
    @State private var appDatabase: AppDatabaseManager?
    @State private var showVaultPicker = true

    @MainActor
    init() {
        let viewModel = CaptionViewModel()
        let sidebarViewModel = SidebarViewModel()
        let liveSubtitleOverlayService = LiveSubtitleOverlayService()
        let recordingCoordinator = RecordingCoordinator(
            viewModel: viewModel,
            sidebarViewModel: sidebarViewModel
        )
        let menuBarCalendarViewModel = MenuBarCalendarViewModel()
        let liveSubtitleOverlayCoordinator = LiveSubtitleOverlayCoordinator(
            viewModel: viewModel,
            liveSubtitleOverlayService: liveSubtitleOverlayService
        )
        let chatCoordinator = CodexChatCoordinator()

        _viewModel = StateObject(wrappedValue: viewModel)
        _sidebarViewModel = State(initialValue: sidebarViewModel)
        _liveSubtitleOverlayService = StateObject(wrappedValue: liveSubtitleOverlayService)
        _recordingCoordinator = State(initialValue: recordingCoordinator)
        _menuBarCalendarViewModel = State(initialValue: menuBarCalendarViewModel)
        _liveSubtitleOverlayCoordinator = State(initialValue: liveSubtitleOverlayCoordinator)
        _chatCoordinator = State(initialValue: chatCoordinator)
    }

    var body: some Scene {
        Window(L10n.dahlia, id: WindowID.main) {
            Group {
                if showVaultPicker {
                    VaultPickerView(appDatabase: appDatabase) { vault in
                        openVault(vault)
                    }
                } else {
                    ContentView(
                        viewModel: viewModel,
                        sidebarViewModel: sidebarViewModel,
                        recordingCoordinator: recordingCoordinator,
                        chatCoordinator: chatCoordinator,
                        onSelectVault: { vault in openVault(vault) }
                    )
                }
            }
            .task {
                _ = liveSubtitleOverlayCoordinator
                initializeAppIfNeeded()
                let settings = AppSettings.shared
                async let driveRestore: Void = GoogleDriveStore.shared.restoreSessionIfNeeded()
                if settings.isCalendarSourceEnabled(.google) {
                    await GoogleCalendarStore.shared.restoreSessionIfNeeded()
                }
                if settings.isCalendarSourceEnabled(.macOS) {
                    await MacCalendarStore.shared.refreshIfNeeded()
                }
                await driveRestore
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: MainWindowMetrics.defaultWidth, height: MainWindowMetrics.defaultHeight)
        .defaultLaunchBehavior(.presented)

        WindowGroup(L10n.chat, id: WindowID.codexChat, for: CodexChatSessionID.self) { $sessionID in
            if let sessionID {
                CodexChatWindowView(
                    coordinator: chatCoordinator,
                    sessionID: sessionID
                )
            } else {
                ContentUnavailableView(
                    L10n.chatWindowUnavailable,
                    systemImage: "bubble.left.and.bubble.right"
                )
            }
        }
        .defaultSize(width: 620, height: 720)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        Window(L10n.vault, id: WindowID.vaultManager) {
            VaultPickerView(appDatabase: appDatabase) { vault in
                openVault(vault)
            }
        }
        .windowStyle(.automatic)

        Window(L10n.projectManagement, id: WindowID.projectManager) {
            ProjectManagementView(sidebarViewModel: sidebarViewModel)
        }
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        Window(L10n.audioRecognitionTest, id: WindowID.audioRecognitionTest) {
            MicrophoneRecognitionTestView(captionViewModel: viewModel)
        }
        .defaultSize(width: 720, height: 700)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        Window(L10n.applicationLogs, id: WindowID.applicationLogs) {
            ApplicationLogView()
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(
                sidebarViewModel: sidebarViewModel,
                onSelectVault: { vault in openVault(vault) }
            )
        }

        MenuBarExtra {
            MenuBarMenuView(
                viewModel: viewModel,
                recordingCoordinator: recordingCoordinator,
                calendarViewModel: menuBarCalendarViewModel
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
        viewModel.configureBatchTranscription(dbQueue: db.dbQueue)

        let repo = MeetingRepository(dbQueue: db.dbQueue)
        if let lastVault = try? repo.fetchLastOpenedVault() {
            openVault(lastVault)
        }
    }

    private func openVault(_ vault: VaultRecord) {
        guard let db = appDatabase else { return }

        if viewModel.isListening {
            viewModel.stopListening()
        }

        try? FileManager.default.createDirectory(at: vault.url, withIntermediateDirectories: true)

        AppSettings.shared.currentVault = vault
        sidebarViewModel.setAppDatabase(db)
        sidebarViewModel.updateVaultLastOpened(vault.id)
        viewModel.prepareAnalyzer()
        meetingDetectionService.isRecording = { [weak viewModel] in viewModel?.isListening ?? false }
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
        showVaultPicker = false
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
        MainWindowOpener.shared.openMainWindow()

        if let event = meeting.calendarEvent {
            let repository = MeetingRepository(dbQueue: db.dbQueue)
            do {
                if let existingMeetingId = try repository.resolveMeetingIdForCalendarEvent(event, vaultId: vault.id) {
                    sidebarViewModel.selectMeeting(existingMeetingId)
                    if startTranscription {
                        startTranscriptionForMeeting(existingMeetingId, in: db, vault: vault)
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
            guard let meetingId = viewModel.materializeDraftMeeting() else { return }
            sidebarViewModel.selectMeeting(meetingId)
            if startTranscription {
                startTranscriptionForMeeting(meetingId, in: db, vault: vault)
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

    private func startTranscriptionForMeeting(_ meetingId: UUID, in db: AppDatabaseManager, vault: VaultRecord) {
        let ctx: (projectURL: URL?, projectId: UUID?, projectName: String?)
        do {
            ctx = try meetingContext(for: meetingId, in: db, vault: vault)
        } catch {
            viewModel.errorMessage = error.localizedDescription
            ErrorReportingService.capture(error, context: ["source": "meetingContext"])
            return
        }
        Task { @MainActor in
            await viewModel.startListening(
                dbQueue: db.dbQueue,
                projectURL: ctx.projectURL,
                vaultId: vault.id,
                projectId: ctx.projectId,
                projectName: ctx.projectName,
                vaultURL: vault.url,
                appendingTo: meetingId
            )
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
        let projectURL = project.map { vault.url.appending(path: $0.name, directoryHint: .isDirectory) }
        return (projectURL, project?.id, project?.name)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private(set) static var hasMutationOwnership = false

    private var isWaitingForCodexShutdown = false
    private var processLock: AdvisoryFileLock?

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
