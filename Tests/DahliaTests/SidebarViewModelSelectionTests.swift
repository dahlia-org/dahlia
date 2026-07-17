import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

@MainActor
struct SidebarViewModelSelectionTests {
    @Test
    func selectMeetingStoresSingleSelection() {
        let viewModel = SidebarViewModel()
        let meetingId = UUID.v7()

        viewModel.selectMeeting(meetingId)

        #expect(viewModel.selectedMeetingIds == [meetingId])
        #expect(viewModel.selectedMeetingId == meetingId)
    }

    @Test
    func selectedMeetingIdIsNilForMultipleSelection() {
        let viewModel = SidebarViewModel()
        let firstMeetingId = UUID.v7()
        let secondMeetingId = UUID.v7()

        viewModel.selectedMeetingIds = [firstMeetingId, secondMeetingId]

        #expect(viewModel.selectedMeetingId == nil)
    }

    @Test
    func clearMeetingSelectionClearsListSelection() {
        let viewModel = SidebarViewModel()
        viewModel.selectedMeetingIds = [UUID.v7(), UUID.v7()]

        viewModel.clearMeetingSelection()

        #expect(viewModel.selectedMeetingIds.isEmpty)
        #expect(viewModel.selectedMeetingId == nil)
    }

    @Test
    func projectDescriptionDraftSurvivesViewRecreation() {
        let viewModel = SidebarViewModel()
        let projectId = UUID.v7()

        viewModel.stageProjectDescriptionDraft(id: projectId, description: "Unsaved description")

        #expect(viewModel.projectDescriptionDraft(id: projectId) == "Unsaved description")
    }
}
#endif
