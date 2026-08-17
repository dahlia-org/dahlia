import SwiftUI

struct ProjectEditorPresentation: View {
    let request: ProjectEditorRequest
    let parentProjects: [ProjectOverviewItem]
    let projectName: String
    let appearance: ProjectAppearance
    let onCancel: () -> Void
    let onDelete: (() -> Void)?
    let onSave: (String, String, UUID?, ProjectType, ProjectAppearance) async -> String?

    @State private var isSaving = false

    var body: some View {
        let project = request.project
        ZStack {
            Button(action: cancel) {
                Color.black.opacity(0.16)
                    .ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

            ProjectEditorSheet(
                title: project == nil ? L10n.createProject : L10n.editProject,
                actionTitle: project == nil ? L10n.createProject : L10n.save,
                parentProjects: parentProjects,
                projectName: projectName,
                projectDescription: request.initialDescription,
                parentProjectId: project?.parentProjectId,
                projectType: project?.effectiveProjectType ?? .undefined,
                appearance: appearance,
                isSaving: $isSaving,
                initiallyFocusesName: project == nil,
                onCancel: cancel,
                onDelete: onDelete,
                onSave: onSave
            )
        }
        .transition(.identity)
    }

    private func cancel() {
        guard !isSaving else { return }
        onCancel()
    }
}
