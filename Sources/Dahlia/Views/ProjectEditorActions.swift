import SwiftUI

struct ProjectEditorActions: View {
    let actionTitle: String
    let isSaving: Bool
    let isSaveDisabled: Bool
    let onCancel: () -> Void
    let onDelete: (() -> Void)?
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let onDelete {
                Button(L10n.deleteProject, systemImage: "trash", role: .destructive, action: onDelete)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.extraLarge)
                    .disabled(isSaving)
            }

            Spacer()

            Button(role: .cancel, action: onCancel) {
                Text(L10n.cancel)
                    .frame(minWidth: 72)
            }
            .buttonStyle(.bordered)
            .controlSize(.extraLarge)
            .keyboardShortcut(.cancelAction)
            .disabled(isSaving)

            Button(action: onSave) {
                Group {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(L10n.saving)
                    } else {
                        Text(actionTitle)
                    }
                }
                .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .disabled(isSaveDisabled || isSaving)
        }
    }
}
