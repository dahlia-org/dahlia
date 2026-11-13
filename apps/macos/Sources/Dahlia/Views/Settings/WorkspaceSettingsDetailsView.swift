import SwiftUI

struct WorkspaceSettingsDetailsView: View {
    let workspace: WorkspaceRecord
    let accountName: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Button(action: onClose) {
                Color.black.opacity(0.16).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 20) {
                ProjectEditorSheetHeader(title: L10n.workspaceDetails, isDisabled: false, onClose: onClose)

                Form {
                    Section {
                        LabeledContent(L10n.workspaceName, value: workspace.name)
                        LabeledContent(L10n.account, value: accountName)
                        LabeledContent(L10n.localExportFolder) {
                            Text(workspace.path ?? L10n.noLocalExportFolder)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        LabeledContent(L10n.summaryOutputLanguage, value: workspace.generationSettings.outputLanguage.displayName)
                    }
                }
                .formStyle(.grouped)
                .textSelection(.enabled)

                HStack {
                    Spacer()
                    Button(L10n.close, action: onClose)
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .font(.dahliaBody)
            .padding(24)
            .frame(width: 560, height: 360)
            .dahliaModalSurface()
        }
    }
}
