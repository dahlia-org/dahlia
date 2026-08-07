import Foundation

enum ProjectManagementSelection {
    static func reconciled(
        selectedProjectId: UUID?,
        projects: [ProjectOverviewItem]
    ) -> UUID? {
        if let selectedProjectId,
           projects.contains(where: { $0.projectId == selectedProjectId }) {
            return selectedProjectId
        }
        return projects.first?.projectId
    }
}
