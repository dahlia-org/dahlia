import AppKit
import SwiftUI

enum WindowID {
    static let main = "main"
    static let vaultManager = "vault-manager"
    static let projectManager = "project-manager"
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
        let liveSubtitleOverlayCoordinator = LiveSubtitleOverlayCoordinator(
            viewModel: viewModel,
            liveSubtitleOverlayService: liveSubtitleOverlayService
        )

        _viewModel = StateObject(wrappedValue: viewModel)
        _sidebarViewModel = State(initialValue: sidebarViewModel)
        _liveSubtitleOverlayService = StateObject(wrappedValue: liveSubtitleOverlayService)
        _recordingCoordinator = State(initialValue: recordingCoordinator)
        _liveSubtitleOverlayCoordinator = State(initialValue: liveSubtitleOverlayCoordinator)
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
                        onSelectVault: { vault in openVault(vault) }
                    )
                }
            }
            .task {
                _ = liveSubtitleOverlayCoordinator
                initializeAppIfNeeded()
                let settings = AppSettings.shared
                if settings.isCalendarSourceEnabled(.google) {
                    await GoogleCalendarStore.shared.restoreSessionIfNeeded()
                }
                if settings.isCalendarSourceEnabled(.macOS) {
                    await MacCalendarStore.shared.refreshIfNeeded()
                }
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: MainWindowMetrics.defaultWidth, height: MainWindowMetrics.defaultHeight)
        .defaultLaunchBehavior(.presented)

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

        Settings {
            SettingsView(
                sidebarViewModel: sidebarViewModel,
                onSelectVault: { vault in openVault(vault) }
            )
        }

        MenuBarExtra {
            MenuBarMenuView(
                viewModel: viewModel,
                recordingCoordinator: recordingCoordinator
            )
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.menu)
    }

    private func initializeAppIfNeeded() {
        guard appDatabase == nil else { return }
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
            if let existingMeetingId = try? repository.fetchMeetingIdForCalendarEvent(event, vaultId: vault.id) {
                sidebarViewModel.selectMeeting(existingMeetingId)
                if startTranscription {
                    startTranscriptionForMeeting(existingMeetingId, in: db, vault: vault)
                }
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
        let ctx = meetingContext(for: meetingId)
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

    private func meetingContext(for meetingId: UUID) -> (projectURL: URL?, projectId: UUID?, projectName: String?) {
        guard let meetingItem = sidebarViewModel.allMeetings.first(where: { $0.meetingId == meetingId }) else {
            return (nil, nil, nil)
        }

        let projectURL = meetingItem.projectName.map { sidebarViewModel.projectURL(for: $0) }
        return (projectURL, meetingItem.projectId, meetingItem.projectName)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        MeetingNotificationService.shared.install()
        ErrorReportingService.start()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
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
