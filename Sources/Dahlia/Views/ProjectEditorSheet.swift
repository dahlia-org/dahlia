import SwiftUI

struct ProjectEditorSheet: View {
    let title: String
    let actionTitle: String
    let parentProjects: [ProjectOverviewItem]
    let onCancel: () -> Void
    let onDelete: (() -> Void)?
    let initiallyFocusesName: Bool
    let onSave: (String, String, UUID?, ProjectType, ProjectAppearance) async -> String?
    @Binding var isSaving: Bool

    @State private var projectName: String
    @State private var projectDescription: String
    @State private var parentProjectId: UUID?
    @State private var projectType: ProjectType
    @State private var appearance: ProjectAppearance
    @State private var errorMessage = ""
    @FocusState private var isProjectNameFocused: Bool
    @FocusState private var isProjectDescriptionFocused: Bool

    init(
        title: String,
        actionTitle: String,
        parentProjects: [ProjectOverviewItem],
        projectName: String,
        projectDescription: String,
        parentProjectId: UUID?,
        projectType: ProjectType,
        appearance: ProjectAppearance,
        isSaving: Binding<Bool>,
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
        _isSaving = isSaving
        _projectName = State(initialValue: projectName)
        _projectDescription = State(initialValue: projectDescription)
        _parentProjectId = State(initialValue: parentProjectId)
        _projectType = State(initialValue: projectType)
        _appearance = State(initialValue: appearance)
    }

    var body: some View {
        ZStack {
            Button(action: { isProjectNameFocused = false }) {
                Color.clear
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 22) {
                ProjectEditorSheetHeader(title: title, isDisabled: isSaving, onClose: onCancel)

                ScrollView {
                    ZStack {
                        Button(action: { isProjectNameFocused = false }) {
                            Color.clear
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 22) {
                            if !errorMessage.isEmpty {
                                SettingsStatusMessage(
                                    text: errorMessage,
                                    systemImage: "exclamationmark.triangle",
                                    tint: .orange
                                )
                            }

                            ProjectNameAppearanceField(
                                projectName: $projectName,
                                appearance: $appearance,
                                isProjectNameFocused: $isProjectNameFocused,
                                onSubmit: save
                            )

                            ProjectEditorDescriptionField(
                                description: $projectDescription,
                                isFocused: $isProjectDescriptionFocused
                            )

                            ProjectEditorHierarchyFields(
                                parentProjects: parentProjects,
                                parentProjectId: $parentProjectId,
                                projectType: $projectType
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .disabled(isSaving)

                ProjectEditorActions(
                    actionTitle: actionTitle,
                    isSaving: isSaving,
                    isSaveDisabled: trimmedProjectName.isEmpty,
                    onCancel: onCancel,
                    onDelete: onDelete,
                    onSave: save
                )
            }
        }
        .padding(24)
        .frame(width: 560, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultFocus($isProjectNameFocused, initiallyFocusesName)
    }

    private var trimmedProjectName: String {
        projectName.trimmingCharacters(in: .whitespacesAndNewlines)
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
