import SwiftUI

struct ChatGPTAccountSettingsView<LeadingContent: View>: View {
    let controller: CodexAccountController
    let title: String
    let footer: String?
    let leadingContent: LeadingContent
    @State private var actionTask: Task<Void, Never>?

    init(
        controller: CodexAccountController,
        title: String,
        footer: String? = nil,
        @ViewBuilder leadingContent: () -> LeadingContent
    ) {
        self.controller = controller
        self.title = title
        self.footer = footer
        self.leadingContent = leadingContent()
    }

    var body: some View {
        Section {
            leadingContent
            content
        } header: {
            Text(title)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
        .task {
            await controller.activateChatGPTSubscription()
        }
        .onDisappear {
            actionTask?.cancel()
            actionTask = nil
        }
    }

    @ViewBuilder
    private var content: some View {
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
                .buttonStyle(.dahlia())
        } else if controller.accountStatus?.isAuthenticated == true {
            Button(L10n.signOut, action: signOut)
                .buttonStyle(.dahlia())
                .disabled(controller.isBusy)
        } else if controller.accountStatus?.requiresOpenAIAuth != false {
            Button(L10n.signInWithChatGPT, action: signIn)
                .buttonStyle(.dahlia(.primary))
                .disabled(controller.isBusy)
        }

        if controller.errorMessage != nil {
            Button(L10n.retry, action: activate)
                .buttonStyle(.dahlia())
                .disabled(controller.isBusy)
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

    private func activate() {
        startAction { await controller.activateChatGPTSubscription() }
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

extension ChatGPTAccountSettingsView where LeadingContent == EmptyView {
    init(controller: CodexAccountController = CodexAccountController()) {
        self.init(
            controller: controller,
            title: L10n.chatGPTSubscription
        ) {
            EmptyView()
        }
    }
}
