import SwiftUI

struct WorkspaceAppearanceButton: View {
    let workspace: WorkspaceRecord
    let onSave: (ProjectAppearance) async -> Bool

    @State private var isPresented = false
    @State private var draft = ProjectAppearance.workspaceDefault
    @State private var isSaving = false

    var body: some View {
        Button {
            draft = workspace.appearance ?? .workspaceDefault
            isPresented = true
        } label: {
            ProjectAppearanceIcon(appearance: workspace.appearance ?? .workspaceDefault)
                .padding(6)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .disabled(!workspace.allowsWorkspaceManagement)
        .help(L10n.appearance)
        .accessibilityLabel(L10n.appearance)
        .popover(isPresented: $isPresented) {
            VStack {
                ProjectAppearancePicker(appearance: $draft)
                    .disabled(isSaving)
                HStack {
                    Button(L10n.cancel) { isPresented = false }
                    Spacer()
                    Button(L10n.save) {
                        isSaving = true
                        Task {
                            if await onSave(draft) { isPresented = false }
                            isSaving = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .disabled(isSaving)
                .padding([.horizontal, .bottom], 12)
            }
        }
    }
}
