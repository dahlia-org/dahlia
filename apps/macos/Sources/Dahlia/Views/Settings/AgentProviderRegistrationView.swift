import SwiftUI

/// Adds a provider to the open account: the Local Account's OpenAI or Anthropic subscription, or a Databricks workspace
/// for MCP servers. Each signs in in the browser.
struct AgentProviderRegistrationView: View {
    enum Kind: Hashable {
        case subscription(PiSubscription)
        case databricks
    }

    let model: AgentMCPSettingsModel
    /// The Local Account's subscriptions; other accounts have none.
    let subscriptions: [CodexAccountController]
    let onClose: () -> Void

    @State private var kind: Kind
    @State private var workspaceURL = ""
    @State private var signInTask: Task<Void, Never>?
    @State private var errorMessage: String?

    init(model: AgentMCPSettingsModel, subscriptions: [CodexAccountController], onClose: @escaping () -> Void) {
        self.model = model
        self.subscriptions = subscriptions
        self.onClose = onClose
        let available = subscriptions.first { $0.accountStatus?.isAuthenticated != true }
        _kind = State(initialValue: available.map { .subscription($0.subscription) } ?? .databricks)
    }

    private var canSignIn: Bool {
        guard signInTask == nil else { return false }
        switch kind {
        case .databricks:
            return !workspaceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .subscription(subscription):
            // A controller checking its status ignores a sign-in, so the button waits for it. One signed in already is
            // listed under Providers, even if it was chosen before its status arrived.
            guard let controller = subscriptions.first(where: { $0.subscription == subscription }) else { return false }
            return !controller.isBusy && controller.accountStatus?.isAuthenticated != true
        }
    }

    var body: some View {
        ZStack {
            Button(action: cancel) {
                Color.black.opacity(0.16).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.addProviderTitle)
                    .font(.dahliaTitle2)
                    .accessibilityAddTraits(.isHeader)
                Picker(L10n.agentProviders, selection: $kind) {
                    ForEach(subscriptions, id: \.subscription) { controller in
                        // A subscription that is signed in already is listed under Providers.
                        let isAdded = controller.accountStatus?.isAuthenticated == true
                        Text(isAdded ? L10n.agentProviderAdded(controller.subscription.displayName) : controller.subscription.displayName)
                            .font(.dahliaBody)
                            .tag(Kind.subscription(controller.subscription))
                            .selectionDisabled(isAdded)
                    }
                    Text(L10n.databricksUnityGateway).font(.dahliaBody).tag(Kind.databricks)
                }
                .disabled(signInTask != nil)

                if kind == .databricks {
                    databricksSection
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    if signInTask != nil {
                        ProgressView().controlSize(.small)
                        Text(L10n.dahliaWaitingForBrowser).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(signInTask == nil ? L10n.cancel : L10n.cancelSignIn, action: cancel)
                        .buttonStyle(.dahlia())
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.dahliaSignIn, action: signIn)
                        .buttonStyle(.dahlia(.primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSignIn)
                }
            }
            .padding(24)
            .frame(width: 520)
            .dahliaModalSurface()
        }
        .transition(.identity)
        .onDisappear { signInTask?.cancel() }
    }

    private var databricksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(L10n.workspaceURL) {
                TextField(L10n.workspaceURL, text: $workspaceURL, prompt: Text(L10n.databricksWorkspaceURLPlaceholder))
                    .labelsHidden()
                    .textContentType(.URL)
                    .onSubmit(signIn)
            }
        }
        .disabled(signInTask != nil)
    }

    private func signIn() {
        guard canSignIn else { return }
        errorMessage = nil
        switch kind {
        case let .subscription(subscription):
            guard let controller = subscriptions.first(where: { $0.subscription == subscription }) else { return }
            signInTask = Task {
                await controller.signIn()
                if Task.isCancelled {
                    // Cancel has closed the modal already; a sign-in Pi saved still appears under Providers.
                } else if controller.accountStatus?.isAuthenticated == true {
                    onClose()
                } else {
                    errorMessage = controller.errorMessage
                }
                signInTask = nil
            }
        case .databricks:
            signInTask = Task {
                do {
                    _ = try await model.addWorkspace(workspaceURL: workspaceURL)
                    onClose()
                } catch is CancellationError {
                    // Closing the modal stops the browser sign-in.
                } catch {
                    errorMessage = error.localizedDescription
                }
                signInTask = nil
            }
        }
    }

    /// Closing the modal also stops a pending browser sign-in, like the backdrop.
    private func cancel() {
        signInTask?.cancel()
        onClose()
    }
}
