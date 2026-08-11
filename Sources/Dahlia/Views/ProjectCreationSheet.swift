import SwiftUI

struct ProjectCreationSheet: View {
    let parentName: String?
    @Binding var projectName: String
    @Binding var projectType: ProjectType
    let errorMessage: String
    let onCancel: () -> Void
    let onCreate: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.parentProject, value: parentName ?? L10n.vaultRoot)
                TextField(L10n.projectName, text: $projectName)
                if parentName == nil {
                    Picker(L10n.projectType, selection: $projectType) {
                        ForEach(ProjectType.allCases, id: \.self) { type in
                            Text(L10n.projectTypeName(type)).tag(type)
                        }
                    }
                } else {
                    Text(L10n.subprojectTypeInheritanceHelp)
                        .foregroundStyle(.secondary)
                }
                if !errorMessage.isEmpty {
                    SettingsStatusMessage(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 220)
        .navigationTitle(L10n.newProject)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button(L10n.cancel, role: .cancel, action: onCancel)
                Button(L10n.create, action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(.bar)
        }
    }
}
