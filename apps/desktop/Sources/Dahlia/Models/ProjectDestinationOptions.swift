import Foundation

enum ProjectDestinationOptions {
    static func reparentCandidates(
        for project: ProjectOverviewItem,
        projects: [ProjectOverviewItem]
    ) -> [ProjectOverviewItem] {
        let hierarchyIDs = hierarchyIDs(for: project.projectId, projects: projects)
        let canBecomeSubproject = project.parentProjectId != nil || hierarchyIDs.count == 1
        guard canBecomeSubproject else { return [] }

        return projects.filter {
            $0.parentProjectId == nil
                && !hierarchyIDs.contains($0.projectId)
        }
    }

    static func meetingMoveCandidates(
        whenDeleting project: ProjectOverviewItem,
        projects: [ProjectOverviewItem]
    ) -> [ProjectOverviewItem] {
        let hierarchyIDs = hierarchyIDs(for: project.projectId, projects: projects)
        return projects.filter {
            !hierarchyIDs.contains($0.projectId)
        }
    }

    static func hierarchy(
        for project: ProjectOverviewItem,
        projects: [ProjectOverviewItem]
    ) -> [ProjectOverviewItem] {
        let hierarchyIDs = hierarchyIDs(for: project.projectId, projects: projects)
        return projects.filter { hierarchyIDs.contains($0.projectId) }
    }

    private static func hierarchyIDs(
        for projectId: UUID,
        projects: [ProjectOverviewItem]
    ) -> Set<UUID> {
        let childrenByParent = Dictionary(grouping: projects, by: \.parentProjectId)
        var result: Set<UUID> = []

        func append(_ id: UUID) {
            guard result.insert(id).inserted else { return }
            for child in childrenByParent[id, default: []] {
                append(child.projectId)
            }
        }

        append(projectId)
        return result
    }
}
