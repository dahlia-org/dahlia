import SwiftUI

/// Bundled Codex app-server and Dahlia-specific ChatGPT account status.
struct AccountSettingsView: View {
    @State private var controller = CodexAccountController()
    @State private var actionTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.codexVersion, value: CodexBundle.version)

                if controller.isCheckingStatus || controller.isSigningOut {
                    LabeledContent(L10n.codexAccount) {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else if let accountStatus = controller.accountStatus {
                    SettingsStatusMessage(
                        text: statusText(accountStatus),
                        systemImage: accountStatus.canUseCodex ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark",
                        tint: accountStatus.canUseCodex ? .green : .orange
                    )
                }

                if controller.isSigningIn {
                    SettingsStatusMessage(
                        text: L10n.codexWaitingForBrowserSignIn,
                        systemImage: "safari",
                        tint: .secondary
                    )
                }

                if let errorMessage = controller.errorMessage {
                    SettingsStatusMessage(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                }

                if controller.isSigningIn {
                    Button(L10n.cancelSignIn, action: cancelSignIn)
                } else if controller.accountStatus?.isAuthenticated == true {
                    Button(L10n.signOut, action: signOut)
                        .disabled(controller.isBusy)
                } else if controller.accountStatus?.requiresOpenAIAuth != false {
                    Button(L10n.signInWithChatGPT, action: signIn)
                        .disabled(controller.isBusy)
                }

                Button(L10n.retry, action: refresh)
                    .disabled(controller.isBusy)
            } header: {
                Text(L10n.codexAppServer)
            } footer: {
                Text(L10n.codexAccountDescription)
            }
        }
        .formStyle(.grouped)
        .task {
            await controller.loadStatus()
        }
        .onDisappear {
            actionTask?.cancel()
            actionTask = nil
        }
    }

    private func statusText(_ status: CodexAppServerService.AccountStatus) -> String {
        if status.isAuthenticated {
            status.label.map(L10n.codexSignedInAs) ?? L10n.codexSignedIn
        } else if !status.requiresOpenAIAuth {
            L10n.codexSignInNotRequired
        } else {
            L10n.codexNotSignedIn
        }
    }

    private func refresh() {
        startAction { await controller.loadStatus() }
    }

    private func signIn() {
        startAction { await controller.signIn() }
    }

    private func cancelSignIn() {
        actionTask?.cancel()
        actionTask = nil
    }

    private func signOut() {
        startAction { await controller.signOut() }
    }

    private func startAction(_ action: @escaping @MainActor () async -> Void) {
        actionTask?.cancel()
        actionTask = Task { await action() }
    }
}
