import SwiftUI

struct ProjectEditorSheet: View {
    let title: String
    let actionTitle: String
    let parentProjects: [ProjectOverviewItem]
    let onCancel: () -> Void
    let onDelete: (() -> Void)?
    let initiallyFocusesName: Bool
    let onSave: (String, String, UUID?, ProjectType, ProjectAppearance) async -> String?

    @State private var projectName: String
    @State private var projectDescription: String
    @State private var parentProjectId: UUID?
    @State private var projectType: ProjectType
    @State private var appearance: ProjectAppearance
    @State private var errorMessage = ""
    @State private var isSaving = false
    @FocusState private var isProjectNameFocused: Bool

    init(
        title: String,
        actionTitle: String,
        parentProjects: [ProjectOverviewItem],
        projectName: String,
        projectDescription: String,
        parentProjectId: UUID?,
        projectType: ProjectType,
        appearance: ProjectAppearance,
        initiallyFocusesName: Bool,
        onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil,
        onSave: @escaping (String, String, UUID?, ProjectType, ProjectAppearance) async -> String?
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.parentProjects = parentProjects
        self.initiallyFocusesName = initiallyFocusesName
        self.onCancel = onCancel
        self.onDelete = onDelete
        self.onSave = onSave
        _projectName = State(initialValue: projectName)
        _projectDescription = State(initialValue: projectDescription)
        _parentProjectId = State(initialValue: parentProjectId)
        _projectType = State(initialValue: projectType)
        _appearance = State(initialValue: appearance)
    }

    var body: some View {
        ZStack {
            Button(action: dismissNameEditing) {
                Color.clear
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 22) {
                ProjectEditorSheetHeader(title: title, isDisabled: isSaving, onClose: cancel)

                Group {
                    ProjectNameAppearanceField(
                        projectName: $projectName,
                        appearance: $appearance,
                        isProjectNameFocused: $isProjectNameFocused
                    )

                    ProjectEditorDescriptionField(description: $projectDescription)

                    ProjectEditorHierarchyFields(
                        parentProjects: parentProjects,
                        parentProjectId: $parentProjectId,
                        projectType: $projectType
                    )
                }
                .disabled(isSaving)

                if !errorMessage.isEmpty {
                    SettingsStatusMessage(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                }

                Spacer(minLength: 0)

                ProjectEditorActions(
                    actionTitle: actionTitle,
                    isSaving: isSaving,
                    isSaveDisabled: trimmedProjectName.isEmpty,
                    onCancel: cancel,
                    onDelete: onDelete,
                    onSave: save
                )
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .dahliaSimpleWindowStyle()
        .defaultFocus($isProjectNameFocused, initiallyFocusesName)
    }

    private var trimmedProjectName: String {
        projectName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cancel() {
        guard !isSaving else { return }
        onCancel()
    }

    private func dismissNameEditing() {
        isProjectNameFocused = false
    }

    private func save() {
        guard !trimmedProjectName.isEmpty, !isSaving else { return }
        isSaving = true
        errorMessage = ""
        Task {
            if let error = await onSave(
                trimmedProjectName,
                projectDescription,
                parentProjectId,
                projectType,
                appearance
            ) {
                errorMessage = error
                isSaving = false
            }
        }
    }
}
