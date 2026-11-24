import SwiftUI

/// The model providers of Settings > Providers > Add Provider, filtered to models: the Pi subscriptions and
/// Databricks. Signing out and removing stay in Settings.
struct ModelProviderSetupStepView: View {
    @State private var controllers = PiSubscription.allCases.map { PiSubscriptionController(subscription: $0) }
    @State private var mcp = AgentMCPSettingsModel()
    /// The list needs a Google registration even though the models filter hides Google.
    @State private var google = GoogleProviderAccountsModel.shared.registrationController()

    var body: some View {
        AgentProviderRegistrationView(
            model: mcp,
            subscriptions: controllers,
            google: google,
            capability: .models,
            isEmbedded: true,
            onClose: {}
        )
        .frame(maxWidth: 520)
        .task {
            await withTaskGroup { group in
                for controller in controllers {
                    group.addTask { await controller.activate() }
                }
            }
        }
        // A sign-in made elsewhere (another settings window) updates the rows too.
        .onReceive(NotificationCenter.default.publisher(for: PiRuntimeService.modelsDidChange).receive(on: RunLoop.main)) { _ in
            for controller in controllers where !controller.isBusy {
                Task { await controller.activate() }
            }
        }
    }
}
