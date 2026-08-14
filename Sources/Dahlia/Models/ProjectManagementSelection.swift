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

    static func ancestorIDs(
        toReveal projectName: String,
        projects: [ProjectOverviewItem]
    ) -> Set<UUID> {
        Set(projects.compactMap { project in
            projectName.hasPrefix(project.projectName + "/") ? project.projectId : nil
        })
    }
}
