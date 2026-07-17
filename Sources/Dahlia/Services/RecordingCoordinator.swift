import AppKit
import Foundation
import GRDB

/// メインウィンドウ、メニューバー、ツールバーから共通利用する録音開始ロジック。
@MainActor
final class RecordingCoordinator {
    private let viewModel: CaptionViewModel
    private let sidebarViewModel: SidebarViewModel

    init(viewModel: CaptionViewModel, sidebarViewModel: SidebarViewModel) {
        self.viewModel = viewModel
        self.sidebarViewModel = sidebarViewModel
    }

    var canStartNewMeeting: Bool {
        viewModel.canBeginRecording
            && sidebarViewModel.dbQueue != nil
            && sidebarViewModel.currentVault != nil
    }

    func startNewMeeting() {
        guard canStartNewMeeting,
              let dbQueue = sidebarViewModel.dbQueue,
              let vault = sidebarViewModel.currentVault else {
            MainWindowOpener.shared.openMainWindow()
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
                vaultURL: vault.url
            )
            if let newMeetingId = viewModel.currentMeetingId {
                sidebarViewModel.selectMeeting(newMeetingId)
            }
        }
    }

    func createEmptyMeeting() {
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
        MainWindowOpener.shared.openMainWindow()
        guard let dbQueue = sidebarViewModel.dbQueue,
              let vault = sidebarViewModel.currentVault else { return }

        let repository = MeetingRepository(dbQueue: dbQueue)
        do {
            if let existingMeetingId = try repository.resolveMeetingIdForCalendarEvent(event, vaultId: vault.id) {
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

    @discardableResult
    func startRecording(appendingTo meetingId: UUID) -> Bool {
        guard canStartNewMeeting,
              let dbQueue = sidebarViewModel.dbQueue,
              let vault = sidebarViewModel.currentVault else {
            MainWindowOpener.shared.openMainWindow()
            return false
        }

        let item = sidebarViewModel.allMeetings.first(where: { $0.meetingId == meetingId })
        guard item != nil || viewModel.currentMeetingId == meetingId else {
            MainWindowOpener.shared.openMainWindow()
            return false
        }
        let projectName = item?.projectName ?? viewModel.currentProjectName
        let projectId = item?.projectId ?? viewModel.currentProjectId

        Task {
            await viewModel.startListening(
                dbQueue: dbQueue,
                projectURL: projectName.map { sidebarViewModel.projectURL(for: $0) },
                vaultId: vault.id,
                projectId: projectId,
                projectName: projectName,
                vaultURL: vault.url,
                appendingTo: meetingId
            )
            sidebarViewModel.selectMeeting(meetingId)
        }
        return true
    }

    func stopRecording() {
        viewModel.stopListening()
    }

    @discardableResult
    private func startRecording(forCalendarEvent event: CalendarEvent) -> Bool {
        guard canStartNewMeeting,
              let dbQueue = sidebarViewModel.dbQueue,
              let vault = sidebarViewModel.currentVault else {
            MainWindowOpener.shared.openMainWindow()
            return false
        }

        let repository = MeetingRepository(dbQueue: dbQueue)
        do {
            if let existingMeetingId = try repository.resolveMeetingIdForCalendarEvent(event, vaultId: vault.id) {
                sidebarViewModel.selectMeeting(existingMeetingId)
                return startRecording(appendingTo: existingMeetingId)
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
        startNewMeeting()
        return true
    }
}
