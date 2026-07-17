import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

@MainActor
struct ProjectDescriptionEditingStateTests {
    @Test
    func restoredDraftKeepsPersistedDescriptionAsSaveBaseline() {
        let state = ProjectDescriptionEditingState(
            persistedText: "Saved description",
            draftText: "Unsaved description"
        )

        #expect(state.text == "Unsaved description")
        #expect(state.persistedText == "Saved description")
        #expect(state.hasUnsavedChanges)
    }

    @Test
    func programmaticDraftRestorationDoesNotRequestSave() {
        var tracker = ProjectDescriptionChangeTracker()

        tracker.prepareForProgrammaticChange(from: "", to: "Unsaved description")
        let shouldSaveRestoredDraft = tracker.shouldSaveChange(to: "Unsaved description")
        let shouldSaveUserEdit = tracker.shouldSaveChange(to: "Edited description")

        #expect(!shouldSaveRestoredDraft)
        #expect(shouldSaveUserEdit)
    }

    @Test
    func unchangedProgrammaticValueDoesNotSuppressLaterUserEdit() {
        var tracker = ProjectDescriptionChangeTracker()

        tracker.prepareForProgrammaticChange(from: "", to: "")
        let shouldSaveUserEdit = tracker.shouldSaveChange(to: "User description")

        #expect(shouldSaveUserEdit)
    }

    @Test
    func missingProjectDoesNotRemainAFailedDraft() throws {
        let database = try AppDatabaseManager(path: ":memory:")
        let viewModel = SidebarViewModel()
        let deletedProjectId = UUID.v7()
        viewModel.setAppDatabase(database)
        viewModel.stageProjectDescriptionDraft(id: deletedProjectId, description: "Unsaved description")

        let result = viewModel.updateProjectDescription(
            id: deletedProjectId,
            description: "Unsaved description"
        )

        #expect(result == .projectNotFound)
        #expect(viewModel.projectDescriptionDraft(id: deletedProjectId) == nil)
    }
}
#endif
