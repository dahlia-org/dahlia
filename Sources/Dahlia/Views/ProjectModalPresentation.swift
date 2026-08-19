import SwiftUI

private struct ProjectModalPresentationModifier: ViewModifier {
    @Binding var editorRequest: ProjectEditorRequest?
    @Binding var deletionProject: ProjectOverviewItem?

    let projects: [ProjectOverviewItem]
    let appearanceForProject: (ProjectOverviewItem) -> ProjectAppearance
    let onCancelEditor: () -> Void
    let onDeleteFromEditor: (ProjectOverviewItem) -> Void
    let onSave: (ProjectEditorRequest, String, String, UUID?, ProjectType, ProjectAppearance) async -> String?
    let onCancelDeletion: () -> Void
    let onConfirmDeletion: (ProjectOverviewItem, ProjectMeetingDisposition, Bool) async -> String?

    func body(content: Content) -> some View {
        ZStack {
            content
                .disabled(isPresentingModal)
                .accessibilityHidden(isPresentingModal)

            if let editorRequest {
                editor(editorRequest)
                    .disabled(deletionProject != nil)
                    .accessibilityHidden(deletionProject != nil)
            }

            if let deletionProject {
                deletionDialog(deletionProject)
            }
        }
        .transition(.identity)
    }

    private func editor(_ request: ProjectEditorRequest) -> some View {
        let project = request.project
        return ProjectEditorPresentation(
            request: request,
            parentProjects: parentProjects(for: project),
            projectName: project.map(displayName) ?? "",
            appearance: project.map(appearanceForProject) ?? .default,
            onCancel: onCancelEditor,
            onDelete: project.map { project in
                { onDeleteFromEditor(project) }
            },
            onSave: { name, description, parentProjectId, projectType, appearance in
                await onSave(request, name, description, parentProjectId, projectType, appearance)
            }
        )
    }

    private func deletionDialog(_ project: ProjectOverviewItem) -> some View {
        let hierarchy = ProjectDestinationOptions.hierarchy(for: project, projects: projects)
        return ProjectDeletionDialog(
            project: project,
            projectCount: hierarchy.count,
            meetingCount: hierarchy.reduce(0) { $0 + $1.meetingCount },
            moveDestinations: ProjectDestinationOptions.meetingMoveCandidates(
                whenDeleting: project,
                projects: projects
            ),
            onCancel: onCancelDeletion,
            onConfirm: { disposition, deletesSummaryFiles in
                await onConfirmDeletion(project, disposition, deletesSummaryFiles)
            }
        )
    }

    private var isPresentingModal: Bool {
        editorRequest != nil || deletionProject != nil
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

extension View {
    func projectModalPresentation(
        editorRequest: Binding<ProjectEditorRequest?>,
        deletionProject: Binding<ProjectOverviewItem?>,
        projects: [ProjectOverviewItem],
        appearanceForProject: @escaping (ProjectOverviewItem) -> ProjectAppearance,
        onCancelEditor: @escaping () -> Void,
        onDeleteFromEditor: @escaping (ProjectOverviewItem) -> Void,
        onSave: @escaping (
            ProjectEditorRequest,
            String,
            String,
            UUID?,
            ProjectType,
            ProjectAppearance
        ) async -> String?,
        onCancelDeletion: @escaping () -> Void,
        onConfirmDeletion: @escaping (
            ProjectOverviewItem,
            ProjectMeetingDisposition,
            Bool
        ) async -> String?
    ) -> some View {
        modifier(ProjectModalPresentationModifier(
            editorRequest: editorRequest,
            deletionProject: deletionProject,
            projects: projects,
            appearanceForProject: appearanceForProject,
            onCancelEditor: onCancelEditor,
            onDeleteFromEditor: onDeleteFromEditor,
            onSave: onSave,
            onCancelDeletion: onCancelDeletion,
            onConfirmDeletion: onConfirmDeletion
        ))
    }
}
