import GRDB
import SwiftUI

struct ProjectBreadcrumbMenu: View {
    let childrenByParent: [UUID?: [ProjectOverviewItem]]
    let parentID: UUID?
    var ancestorIDs: Set<UUID> = []
    let workspaceID: UUID
    let dbQueue: DatabaseQueue?
    let appearanceForProject: (UUID) -> ProjectAppearance
    let onOpenProject: (UUID) -> Void
    let onOpenMeeting: (UUID) -> Void

    var body: some View {
        ForEach(childrenByParent[parentID, default: []].filter {
            !ancestorIDs.contains($0.projectId)
        }.sorted { $0.projectName.localizedStandardCompare($1.projectName) == .orderedAscending }) { project in
            BreadcrumbSwitcher(
                title: project.projectDisplayName.nilIfBlank ?? project.projectName,
                systemImage: appearanceForProject(project.projectId).icon.systemImageName,
                arrowEdge: .trailing,
                action: { onOpenProject(project.projectId) }
            ) {
                Self(
                    childrenByParent: childrenByParent,
                    parentID: project.projectId,
                    ancestorIDs: ancestorIDs.union([project.projectId]),
                    workspaceID: workspaceID,
                    dbQueue: dbQueue,
                    appearanceForProject: appearanceForProject,
                    onOpenProject: onOpenProject,
                    onOpenMeeting: onOpenMeeting
                )
                MeetingBreadcrumbList(
                    workspaceID: workspaceID,
                    projectID: project.projectId,
                    dbQueue: dbQueue,
                    onOpenMeeting: onOpenMeeting
                )
            }
        }
    }
}
