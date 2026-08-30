import SwiftUI

struct ModelProviderSetupStepView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var chatGPTController = CodexAccountController()
    @State private var databricksController = DatabricksAccountController()

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(AIAccountProvider.allCases) { provider in
                        ModelProviderChoiceCard(
                            provider: provider,
                            isSelected: settings.codexAccountProvider == provider
                        ) {
                            settings.codexAccountProvider = provider
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            switch settings.codexAccountProvider {
            case .chatGPTSubscription:
                ChatGPTAccountSettingsView(
                    controller: chatGPTController,
                    showsDescription: false
                )
            case .databricks:
                DatabricksAccountSettingsView(
                    controller: databricksController,
                    restoresProviderSelection: false,
                    showsDescription: false
                )
            }
        }
        .formStyle(.grouped)
        .frame(height: 480)
    }
}
