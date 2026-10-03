import SwiftUI

struct ModelProviderSetupStepView: View {
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var chatGPTController = CodexAccountController()
    @State private var databricksController = DatabricksAccountController()

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(AIAccountProvider.allCases) { provider in
                        ModelProviderChoiceCard(
                            provider: provider,
                            isSelected: workspaceSettings.localProvider == provider
                        ) {
                            workspaceSettings.localProvider = provider
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            switch workspaceSettings.localProvider {
            case .chatGPTSubscription:
                ChatGPTAccountSettingsView(controller: chatGPTController)
            case .databricks:
                DatabricksAccountSettingsView(controller: databricksController)
            }
        }
        .formStyle(.grouped)
        .frame(height: 480)
    }
}
