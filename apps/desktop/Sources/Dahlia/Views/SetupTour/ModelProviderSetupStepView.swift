import SwiftUI

struct ModelProviderSetupStepView: View {
    @Bindable private var vaultSettings = VaultAISettingsModel.shared
    @State private var chatGPTController = CodexAccountController()
    @State private var databricksController = DatabricksAccountController()

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(AIAccountProvider.allCases) { provider in
                        ModelProviderChoiceCard(
                            provider: provider,
                            isSelected: vaultSettings.localProvider == provider
                        ) {
                            vaultSettings.localProvider = provider
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            switch vaultSettings.localProvider {
            case .chatGPTSubscription:
                ChatGPTAccountSettingsView(
                    controller: chatGPTController,
                    showsDescription: false
                )
            case .databricks:
                DatabricksAccountSettingsView(
                    controller: databricksController,
                    showsDescription: false
                )
            }
        }
        .formStyle(.grouped)
        .frame(height: 480)
    }
}
