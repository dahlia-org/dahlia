import SwiftUI

/// Only the Local Account sets up model providers in the tour, even while another account's workspace is open.
/// Each card shows whether its subscription is signed in. Clicking it signs in through the browser or cancels a pending
/// sign-in; each subscription signs in independently, so any number can be signed in. Signing out stays in Settings >
/// Agents, so a click on a signed-in card does nothing.
struct ModelProviderSetupStepView: View {
    @State private var controllers = PiSubscription.allCases.map { CodexAccountController(subscription: $0) }
    @State private var actionTasks: [PiSubscription: Task<Void, Never>] = [:]

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(controllers, id: \.subscription) { controller in
                        let isSignedIn = controller.accountStatus?.isAuthenticated == true
                        SetupChoiceCard(
                            image: controller.subscription.logo,
                            title: controller.subscription.setupTitle,
                            description: controller.isSigningIn
                                ? L10n.codexWaitingForBrowserSignIn
                                : controller.subscription.setupDescription,
                            isSelected: isSignedIn,
                            style: .action,
                            // A status refresh keeps the check of a signed-in card instead of flashing a spinner.
                            isBusy: controller.isBusy && !isSignedIn,
                            selectedAccessibilityValue: L10n.codexSignedIn
                        ) {
                            startOrCancelSignIn(controller)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

                ForEach(controllers, id: \.subscription) { controller in
                    if let errorMessage = controller.errorMessage {
                        LabeledContent(controller.subscription.displayName) {
                            SettingsStatusMessage(text: errorMessage, systemImage: "exclamationmark.triangle.fill", tint: .red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 480)
        .task {
            await withTaskGroup { group in
                for controller in controllers {
                    group.addTask { await controller.activate() }
                }
            }
        }
        // A sign-in made elsewhere (another settings window) updates the cards too.
        .onReceive(NotificationCenter.default.publisher(for: PiRuntimeService.modelsDidChange).receive(on: RunLoop.main)) { _ in
            for controller in controllers where !controller.isBusy {
                Task { await controller.activate() }
            }
        }
        .onDisappear {
            // Leaving the step closes Pi and any sign-in still waiting for the browser.
            actionTasks.values.forEach { $0.cancel() }
            actionTasks = [:]
        }
    }

    private func startOrCancelSignIn(_ controller: CodexAccountController) {
        let subscription = controller.subscription
        if controller.isSigningIn {
            actionTasks[subscription]?.cancel()
            return
        }
        // A failed status check leaves the status unknown; clicking then signs in, which also retries.
        // A second click before the first task has started finds its entry and is ignored.
        guard actionTasks[subscription] == nil, !controller.isBusy, controller.accountStatus?.isAuthenticated != true else {
            return
        }
        actionTasks[subscription] = Task {
            await controller.signIn()
            actionTasks[subscription] = nil
        }
    }
}

private extension PiSubscription {
    /// Product names, so they stay untranslated; the break keeps the plan names on a line of their own.
    var setupTitle: String {
        switch self {
        case .openai: "OpenAI\n(ChatGPT Free/Plus/Pro)"
        case .anthropic: "Anthropic\n(Claude Pro/Max/Ultra)"
        }
    }

    var setupDescription: String {
        switch self {
        case .openai: L10n.openAISubscriptionSetupDescription
        case .anthropic: L10n.anthropicSubscriptionSetupDescription
        }
    }
}
