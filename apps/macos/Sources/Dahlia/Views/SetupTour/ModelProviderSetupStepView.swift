import SwiftUI

/// Only the Local Account sets up model providers in the tour, even while another account's workspace is open.
struct ModelProviderSetupStepView: View {
    @State private var openAIController = CodexAccountController(subscription: .openai)
    @State private var anthropicController = CodexAccountController(subscription: .anthropic)

    var body: some View {
        Form {
            Section {
                SubscriptionAccountSettingsView(controller: openAIController)
                SubscriptionAccountSettingsView(controller: anthropicController)
            }
        }
        .formStyle(.grouped)
        .frame(height: 480)
    }
}
