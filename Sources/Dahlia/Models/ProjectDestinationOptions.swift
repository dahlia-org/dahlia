enum ProjectDestinationOptions {
    static func reparentCandidates(
        for project: ProjectOverviewItem,
        projects: [ProjectOverviewItem]
    ) -> [ProjectOverviewItem] {
        let hierarchy = hierarchy(for: project, projects: projects)
        let canBecomeSubproject = project.parentProjectId != nil || hierarchy.count == 1
        guard canBecomeSubproject else { return [] }

        return projects.filter {
            $0.parentProjectId == nil
                && !ProjectRecord.belongsToHierarchy($0.projectName, prefix: project.projectName)
        }
    }

    static func meetingMoveCandidates(
        whenDeleting project: ProjectOverviewItem,
        projects: [ProjectOverviewItem]
    ) -> [ProjectOverviewItem] {
        projects.filter {
            !ProjectRecord.belongsToHierarchy($0.projectName, prefix: project.projectName)
        }
    }

    static func hierarchy(
        for project: ProjectOverviewItem,
        projects: [ProjectOverviewItem]
    ) -> [ProjectOverviewItem] {
        projects.filter {
            ProjectRecord.belongsToHierarchy($0.projectName, prefix: project.projectName)
        }
    }
}
