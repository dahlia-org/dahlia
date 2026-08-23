import SwiftUI

struct DatabricksProfileCreationView: View {
    let controller: DatabricksAccountController
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var workspaceURL = ""
    @State private var signInTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            DahliaSheetHeader(title: L10n.createNewDatabricksProfile)

            Form {
                Section {
                    TextField(
                        L10n.databricksWorkspaceURL,
                        text: $workspaceURL,
                        prompt: Text(L10n.databricksWorkspaceURLPlaceholder)
                    )
                    .textContentType(.URL)
                    .disabled(controller.isBusy || controller.isCLIAvailable == false)
                    .onSubmit(signIn)
                } header: {
                    Text(L10n.databricksWorkspaceURL)
                } footer: {
                    Text(L10n.databricksWorkspaceURLDescription)
                }

                if controller.isSigningIn {
                    LabeledContent(L10n.codexConfiguration) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(L10n.codexWaitingForBrowserSignIn)
                    }
                } else if controller.isApplyingConfiguration {
                    LabeledContent(L10n.codexConfiguration) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(L10n.codexConfiguration)
                    }
                }

                if controller.isCLIAvailable == false {
                    SettingsStatusMessage(
                        text: L10n.databricksCLINotInstalled,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }

                if let errorMessage = controller.errorMessage {
                    SettingsStatusMessage(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                }
            }
            .formStyle(.grouped)

            DahliaSheetActionBar {
                Button(L10n.cancel) {
                    signInTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.signInWithDatabricks, action: signIn)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.isBusy || controller.isCLIAvailable == false || workspaceURL.nilIfBlank == nil)
            }
        }
        .frame(minWidth: 500, minHeight: 300)
        .dahliaSimpleWindowStyle()
        .onDisappear {
            signInTask?.cancel()
            signInTask = nil
            controller.restoreSelectedProvider()
        }
    }

    private func signIn() {
        guard !controller.isBusy,
              controller.isCLIAvailable != false,
              workspaceURL.nilIfBlank != nil
        else {
            return
        }
        signInTask = Task {
            guard let profileName = await controller.signIn(workspaceURL: workspaceURL),
                  !Task.isCancelled
            else {
                return
            }
            onCreated(profileName)
            dismiss()
        }
    }
}
