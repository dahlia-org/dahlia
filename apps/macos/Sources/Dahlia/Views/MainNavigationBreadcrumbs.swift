import GRDB
import SwiftUI

struct MainNavigationBreadcrumbs: View {
    let workspace: WorkspaceRecord
    let workspaces: [WorkspaceRecord]
    let projects: [UUID: ProjectOverviewItem]
    let projectID: UUID?
    let meetingTitle: String?
    let dbQueue: DatabaseQueue?
    let onOpenMeeting: (UUID) -> Void
    let appearanceForProject: (UUID) -> ProjectAppearance
    let onSelectWorkspace: (WorkspaceRecord) -> Void
    let onShowProjects: () -> Void
    let onOpenProject: (UUID) -> Void

    @State private var hoverSession = BreadcrumbHoverSession()

    var body: some View {
        let childrenByParent = Dictionary(grouping: projects.values, by: \.parentProjectId)
        HStack(spacing: 4) {
            BreadcrumbSwitcher(
                title: workspace.name,
                systemImage: (workspace.appearance ?? .workspaceDefault).icon.systemImageName,
                sectionTitle: L10n.workspace,
                action: onShowProjects
            ) {
                ForEach(workspaces) { item in
                    BreadcrumbNavigationButton(title: item.name, systemImage: (item.appearance ?? .workspaceDefault).icon.systemImageName) {
                        onSelectWorkspace(item)
                    }
                }
            }

            ForEach(Self.projectPath(projectID: projectID, projects: projects)) { project in
                Text("/").accessibilityHidden(true)
                BreadcrumbSwitcher(
                    title: project.projectDisplayName.nilIfBlank ?? project.projectName,
                    systemImage: appearanceForProject(project.projectId).icon.systemImageName,
                    sectionTitle: L10n.projects,
                    action: { onOpenProject(project.projectId) }
                ) {
                    ProjectBreadcrumbMenu(
                        childrenByParent: childrenByParent,
                        parentID: project.parentProjectId,
                        workspaceID: workspace.id,
                        dbQueue: dbQueue,
                        appearanceForProject: appearanceForProject,
                        onOpenProject: onOpenProject,
                        onOpenMeeting: onOpenMeeting
                    )
                }
            }

            if let meetingTitle {
                let title = meetingTitle.nilIfBlank ?? L10n.newMeeting
                Text("/").accessibilityHidden(true)
                BreadcrumbSwitcher(title: title, systemImage: "doc.text", sectionTitle: L10n.meetings, action: {}) {
                    MeetingBreadcrumbList(
                        workspaceID: workspace.id,
                        projectID: projectID,
                        dbQueue: dbQueue,
                        onOpenMeeting: onOpenMeeting
                    )
                    .id(projectID)
                }
                .layoutPriority(-1)
            }
        }
        .environment(hoverSession)
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func projectPath(projectID: UUID?, projects: [UUID: ProjectOverviewItem]) -> [ProjectOverviewItem] {
        var path: [ProjectOverviewItem] = []
        var currentID = projectID
        var visited: Set<UUID> = []
        while let id = currentID, visited.insert(id).inserted, let project = projects[id] {
            path.append(project)
            currentID = project.parentProjectId
        }
        return path.reversed()
    }
}
