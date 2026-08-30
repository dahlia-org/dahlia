import SwiftUI

struct AccountSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var chatGPTController = CodexAccountController()
    @State private var databricksController = DatabricksAccountController()

    var body: some View {
        Form {
            Section {
                DahliaMenuPicker(
                    title: L10n.provider,
                    description: L10n.aiAccountDescription,
                    selection: $settings.codexAccountProvider,
                    options: AIAccountProvider.allCases,
                    label: \.displayName
                )
                .disabled(chatGPTController.isBusy || databricksController.isBusy)

                LabeledContent(L10n.codexVersion, value: CodexBundle.version)
            } header: {
                Text(L10n.modelProvider)
            } footer: {
                Text(L10n.aiAccountSettingsDescription)
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
