import SwiftUI

/// One Local Account subscription's row. Each subscription signs in and out independently of the others.
struct SubscriptionAccountSettingsView: View {
    let controller: CodexAccountController
    @State private var actionTask: Task<Void, Never>?

    var body: some View {
        LabeledContent(controller.subscription.displayName) {
            HStack {
                if controller.isCheckingStatus || controller.isSigningOut {
                    ProgressView()
                        .controlSize(.small)
                } else if controller.isSigningIn {
                    Text(L10n.codexWaitingForBrowserSignIn)
                        .foregroundStyle(.secondary)
                    Button(L10n.cancelSignIn, action: cancelSignIn)
                        .buttonStyle(.dahlia())
                } else if controller.accountStatus?.isAuthenticated == true {
                    Label(L10n.codexSignedIn, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button(L10n.signOut, action: signOut)
                        .buttonStyle(.dahlia())
                        .disabled(controller.isBusy)
                } else {
                    Button(signInTitle, action: signIn)
                        .buttonStyle(.dahlia(.primary))
                        .disabled(controller.isBusy)
                }
            }
        }
        .task {
            await controller.activate()
        }
        // A sign-in made elsewhere (setup tour or another settings window) updates this status too.
        .onReceive(NotificationCenter.default.publisher(for: PiRuntimeService.modelsDidChange).receive(on: RunLoop.main)) { _ in
            guard !controller.isBusy else { return }
            Task { await controller.activate() }
        }
        .onDisappear {
            actionTask?.cancel()
            actionTask = nil
        }

        if let errorMessage = controller.errorMessage {
            HStack {
                SettingsStatusMessage(text: errorMessage, systemImage: "exclamationmark.triangle.fill", tint: .red)
                Spacer()
                Button(L10n.retry, action: activate)
                    .buttonStyle(.dahlia())
                    .disabled(controller.isBusy)
            }
        }
    }

    private var signInTitle: String {
        switch controller.subscription {
        case .openai: L10n.signInWithChatGPT
        case .anthropic: L10n.signInWithClaude
        }
    }

    private func activate() {
        startAction { await controller.activate() }
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
