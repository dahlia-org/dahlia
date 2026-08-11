#if canImport(Testing)
import Foundation
import Testing
@testable import Dahlia

struct ProjectManagementSelectionTests {
    @Test
    func preservesSelectionWhenProjectStillExists() {
        let first = project(named: "First")
        let selected = project(named: "Selected")

        let result = ProjectManagementSelection.reconciled(
            selectedProjectId: selected.projectId,
            projects: [first, selected]
        )

        #expect(result == selected.projectId)
    }

    @Test
    func selectsFirstProjectWhenSelectionWasDeletedOrVaultChanged() {
        let first = project(named: "First")

        let result = ProjectManagementSelection.reconciled(
            selectedProjectId: UUID.v7(),
            projects: [first, project(named: "Second")]
        )

        #expect(result == first.projectId)
    }

    @Test
    func clearsSelectionWhenProjectListIsEmpty() {
        let result = ProjectManagementSelection.reconciled(
            selectedProjectId: UUID.v7(),
            projects: []
        )

        #expect(result == nil)
    }

    private func project(named name: String) -> ProjectOverviewItem {
        ProjectOverviewItem(
            projectId: .v7(),
            projectName: name,
            projectDisplayName: name,
            parentProjectId: nil,
            projectDescription: "",
            explicitProjectType: .undefined,
            effectiveProjectType: .undefined,
            typeOwnerProjectId: nil,
            revision: 0,
            createdAt: .now,
            meetingCount: 0,
            latestMeetingDate: nil
        )
    }
}
#endif
