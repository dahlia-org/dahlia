import SwiftUI

struct ProjectModalPresentation: View {
    let editorRequest: ProjectEditorRequest?
    let deletionProject: ProjectOverviewItem?
    let projects: [ProjectOverviewItem]
    let appearanceForProject: (ProjectOverviewItem) -> ProjectAppearance
    let onCancelEditor: () -> Void
    let onDeleteFromEditor: (ProjectOverviewItem) -> Void
    let onSave: (ProjectEditorRequest, String, String, UUID?, ProjectType, ProjectAppearance) async -> String?
    let onCancelDeletion: () -> Void
    let onConfirmDeletion: (ProjectOverviewItem, ProjectMeetingDisposition, Bool) async -> String?

    var body: some View {
        ZStack {
            if let editorRequest {
                let project = editorRequest.project
                ProjectEditorPresentation(
                    request: editorRequest,
                    parentProjects: parentProjects(for: project),
                    projectName: project.map(displayName) ?? "",
                    appearance: project.map(appearanceForProject) ?? .default,
                    onCancel: onCancelEditor,
                    onDelete: project.map { project in
                        { onDeleteFromEditor(project) }
                    },
                    onSave: { name, description, parentProjectId, projectType, appearance in
                        await onSave(editorRequest, name, description, parentProjectId, projectType, appearance)
                    }
                )
                .disabled(deletionProject != nil)
                .accessibilityHidden(deletionProject != nil)
            }

            if let deletionProject {
                let hierarchy = ProjectDestinationOptions.hierarchy(for: deletionProject, projects: projects)
                ProjectDeletionDialog(
                    project: deletionProject,
                    projectCount: hierarchy.count,
                    meetingCount: hierarchy.reduce(0) { $0 + $1.meetingCount },
                    moveDestinations: ProjectDestinationOptions.meetingMoveCandidates(
                        whenDeleting: deletionProject,
                        projects: projects
                    ),
                    onCancel: onCancelDeletion,
                    onConfirm: { disposition, deletesSummaryFiles in
                        await onConfirmDeletion(deletionProject, disposition, deletesSummaryFiles)
                    }
                )
            }
        }
    }

    private func parentProjects(for project: ProjectOverviewItem?) -> [ProjectOverviewItem] {
        guard let project else {
            return projects.filter { $0.parentProjectId == nil }
        }
        return ProjectDestinationOptions.reparentCandidates(for: project, projects: projects)
    }

    private func displayName(_ project: ProjectOverviewItem) -> String {
        project.projectDisplayName.nilIfBlank
            ?? project.projectName.split(separator: "/").last.map(String.init)
            ?? project.projectName
    }
}
