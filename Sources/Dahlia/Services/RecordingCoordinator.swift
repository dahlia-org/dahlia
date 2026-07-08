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
        !viewModel.isListening
            && !viewModel.isFinalizingRecording
            && viewModel.analyzerReady
            && viewModel.hasEnabledAudioSource
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

    func startRecording(appendingTo meetingId: UUID) {
        guard canStartNewMeeting,
              let dbQueue = sidebarViewModel.dbQueue,
              let vault = sidebarViewModel.currentVault else {
            MainWindowOpener.shared.openMainWindow()
            return
        }

        let item = sidebarViewModel.allMeetings.first(where: { $0.meetingId == meetingId })
        guard item != nil || viewModel.currentMeetingId == meetingId else {
            MainWindowOpener.shared.openMainWindow()
            return
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
    }

    func stopRecording() {
        viewModel.stopListening()
    }
}
