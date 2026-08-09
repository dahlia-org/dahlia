import AppKit
import Foundation
import GRDB

/// メインウィンドウ、メニューバー、ツールバーから共通利用する録音開始ロジック。
@MainActor
final class RecordingCoordinator {
    private let viewModel: CaptionViewModel
    private let sidebarViewModel: SidebarViewModel
    private let mainWindowNavigation: MainWindowNavigation
    private let meetingDetectionService: MeetingDetectionService

    init(
        viewModel: CaptionViewModel,
        sidebarViewModel: SidebarViewModel,
        mainWindowNavigation: MainWindowNavigation,
        meetingDetectionService: MeetingDetectionService
    ) {
        self.viewModel = viewModel
        self.sidebarViewModel = sidebarViewModel
        self.mainWindowNavigation = mainWindowNavigation
        self.meetingDetectionService = meetingDetectionService
    }

    var canStartNewMeeting: Bool {
        viewModel.canBeginRecording
            && sidebarViewModel.dbQueue != nil
            && sidebarViewModel.currentVault != nil
    }

    func startNewMeeting() {
        startNewMeeting(opensMainWindowOnFailure: true)
    }

    private func startNewMeeting(opensMainWindowOnFailure: Bool) {
        mainWindowNavigation.showMeetings()
        guard canStartNewMeeting,
              let dbQueue = sidebarViewModel.dbQueue,
              let vault = sidebarViewModel.currentVault,
              let reservation = viewModel.reserveRecordingStart() else {
            openMainWindowOnFailure(if: opensMainWindowOnFailure)
            return
        }

        let shouldUseDraftMeeting = viewModel.hasDraftMeeting
        let projectURL = shouldUseDraftMeeting ? viewModel.currentProjectURL : nil
        let projectId = shouldUseDraftMeeting ? viewModel.currentProjectId : nil
        let projectName = shouldUseDraftMeeting ? viewModel.currentProjectName : nil

        if !shouldUseDraftMeeting {
            viewModel.clearCurrentMeeting()
        }

        Task {
            await viewModel.startListening(
                dbQueue: dbQueue,
                projectURL: projectURL,
                vaultId: vault.id,
                projectId: projectId,
                projectName: projectName,
                vaultURL: vault.url,
                reservation: reservation
            )
            recordingDidStart()
            if let newMeetingId = viewModel.currentMeetingId {
                sidebarViewModel.selectMeeting(newMeetingId)
            }
        }
    }

    func createEmptyMeeting() {
        mainWindowNavigation.showMeetings()
        guard let dbQueue = sidebarViewModel.dbQueue,
              let vault = sidebarViewModel.currentVault else {
            MainWindowOpener.shared.openMainWindow()
            return
        }

        viewModel.createEmptyMeeting(
            dbQueue: dbQueue,
            projectURL: nil,
            vaultId: vault.id,
            projectId: nil,
            name: "",
            projectName: nil,
            vaultURL: vault.url
        )
        if let meetingId = viewModel.currentMeetingId {
            sidebarViewModel.selectMeeting(meetingId)
        }
    }

    func openCalendarEvent(_ event: CalendarEvent) {
        mainWindowNavigation.openMeetings()
        guard let dbQueue = sidebarViewModel.dbQueue,
              let vault = sidebarViewModel.currentVault else { return }

        let repository = MeetingRepository(dbQueue: dbQueue)
        do {
            if let existingMeetingId = try repository.resolveMeetingIdForCalendarEvent(
                event,
                vaultId: vault.id,
                customerIntelligenceIngestion: .afterMeetingPersistence
            ) {
                sidebarViewModel.selectMeeting(existingMeetingId)
                return
            }
        } catch {
            viewModel.errorMessage = error.localizedDescription
            ErrorReportingService.capture(error, context: ["source": "calendarEventSelection"])
            return
        }

        guard !viewModel.isListening else { return }

        sidebarViewModel.clearMeetingSelection()
        viewModel.beginDraftMeeting(
            from: event,
            dbQueue: dbQueue,
            vaultURL: vault.url
        )
    }

    func joinCalendarEventAndStartRecording(_ event: CalendarEvent) {
        guard startRecording(forCalendarEvent: event),
              let conferenceURI = event.conferenceURI else { return }
        NSWorkspace.shared.open(conferenceURI)
    }

    func startAutomaticRecording(forCalendarEvent event: CalendarEvent) {
        mainWindowNavigation.openMeetingsWithoutActivation()
        startRecording(forCalendarEvent: event, opensMainWindowOnFailure: false)
    }

    @discardableResult
    func startRecording(
        appendingTo meetingId: UUID,
        customerIntelligenceEvent: CalendarEvent? = nil
    ) -> Bool {
        startRecording(
            appendingTo: meetingId,
            customerIntelligenceEvent: customerIntelligenceEvent,
            opensMainWindowOnFailure: true
        )
    }

    @discardableResult
    private func startRecording(
        appendingTo meetingId: UUID,
        customerIntelligenceEvent: CalendarEvent? = nil,
        opensMainWindowOnFailure: Bool
    ) -> Bool {
        mainWindowNavigation.showMeetings()
        guard canStartNewMeeting,
              let dbQueue = sidebarViewModel.dbQueue,
              let vault = sidebarViewModel.currentVault else {
            openMainWindowOnFailure(if: opensMainWindowOnFailure)
            return false
        }

        let item: MeetingSidebarItem
        do {
            guard let fetchedItem = try dbQueue.read({ db in
                try MeetingRepository.fetchMeetingSidebarItems(
                    ids: [meetingId],
                    vaultId: vault.id,
                    in: db
                ).first
            }) else {
                openMainWindowOnFailure(if: opensMainWindowOnFailure)
                return false
            }
            item = fetchedItem
        } catch {
            viewModel.errorMessage = error.localizedDescription
            ErrorReportingService.capture(error, context: ["source": "recordingAppendTarget"])
            openMainWindowOnFailure(if: opensMainWindowOnFailure)
            return false
        }

        guard let reservation = viewModel.reserveRecordingStart() else { return false }

        Task {
            await viewModel.startListening(
                dbQueue: dbQueue,
                projectURL: item.projectName.map { sidebarViewModel.projectURL(for: $0) },
                vaultId: vault.id,
                projectId: item.projectId,
                projectName: item.projectName,
                vaultURL: vault.url,
                appendingTo: meetingId,
                reservation: reservation
            )
            recordingDidStart()
            if let customerIntelligenceEvent,
               viewModel.isListening,
               viewModel.recordingMeetingId == meetingId {
                CustomerIntelligenceIngestionService.schedule(
                    calendarEvent: customerIntelligenceEvent,
                    meetingId: meetingId,
                    vaultId: vault.id,
                    observedAt: .now,
                    dbQueue: dbQueue
                )
            }
            sidebarViewModel.selectMeeting(meetingId)
        }
        return true
    }

    func stopRecording() {
        meetingDetectionService.recordingDidStop()
        viewModel.stopListening()
    }

    func recordingDidStart() {
        guard viewModel.isListening else { return }
        meetingDetectionService.recordingDidStart()
    }

    @discardableResult
    private func startRecording(
        forCalendarEvent event: CalendarEvent,
        opensMainWindowOnFailure: Bool = true
    ) -> Bool {
        mainWindowNavigation.showMeetings()
        guard canStartNewMeeting,
              let dbQueue = sidebarViewModel.dbQueue,
              let vault = sidebarViewModel.currentVault else {
            openMainWindowOnFailure(if: opensMainWindowOnFailure)
            return false
        }

        let repository = MeetingRepository(dbQueue: dbQueue)
        do {
            if let existingMeetingId = try repository.resolveMeetingIdForCalendarEvent(
                event,
                vaultId: vault.id,
                customerIntelligenceIngestion: .afterCaptureStarts
            ) {
                sidebarViewModel.selectMeeting(existingMeetingId)
                return startRecording(
                    appendingTo: existingMeetingId,
                    customerIntelligenceEvent: event,
                    opensMainWindowOnFailure: opensMainWindowOnFailure
                )
            }
        } catch {
            viewModel.errorMessage = error.localizedDescription
            ErrorReportingService.capture(error, context: ["source": "calendarEventRecording"])
            return false
        }

        sidebarViewModel.clearMeetingSelection()
        viewModel.beginDraftMeeting(
            from: event,
            dbQueue: dbQueue,
            vaultURL: vault.url
        )
        startNewMeeting(opensMainWindowOnFailure: opensMainWindowOnFailure)
        return true
    }

    private func openMainWindowOnFailure(if shouldOpen: Bool) {
        guard shouldOpen else { return }
        MainWindowOpener.shared.openMainWindow()
    }
}
