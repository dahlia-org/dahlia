import SwiftUI

struct AccountSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var chatGPTController = CodexAccountController()
    @State private var databricksController = DatabricksAccountController()

    var body: some View {
        Form {
            Section {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280, maximum: 320), spacing: 16)],
                    spacing: 16
                ) {
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
                .disabled(chatGPTController.isBusy || databricksController.isBusy)
            }

            switch settings.codexAccountProvider {
            case .chatGPTSubscription:
                ChatGPTAccountSettingsView(controller: chatGPTController)
            case .databricks:
                DatabricksAccountSettingsView(controller: databricksController)
            }
        }
        .formStyle(.grouped)
    }
}
