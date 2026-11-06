import SwiftUI

/// Model providers of the open account. The Local Account uses the OpenAI and Anthropic subscriptions, signed in
/// independently; a Databricks account uses its workspace's Unity AI Gateway.
struct AccountSettingsView: View {
    @State private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var openAIController = CodexAccountController(subscription: .openai)
    @State private var anthropicController = CodexAccountController(subscription: .anthropic)

    var body: some View {
        Section {
            if workspaceSettings.isDatabricksAccount {
                // The account itself signs out from the account menu.
                Label {
                    Text(L10n.unityGateway)
                } icon: {
                    Image.databricksLogo.resizable().scaledToFit().frame(width: 16, height: 16)
                }
            } else {
                SubscriptionAccountSettingsView(controller: openAIController)
                SubscriptionAccountSettingsView(controller: anthropicController)
            }
        } header: {
            Text(L10n.modelProvider)
        }
    }
}
