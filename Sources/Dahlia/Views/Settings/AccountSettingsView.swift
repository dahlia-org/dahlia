import SwiftUI

struct AccountSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.codexAccountProvider) {
                    ForEach(AIAccountProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                } label: {
                    Text(L10n.account)
                    Text(L10n.aiAccountDescription)
                }
                .pickerStyle(.menu)

                LabeledContent(L10n.codexVersion, value: CodexBundle.version)
            } header: {
                Text(L10n.aiConnection)
            } footer: {
                Text(L10n.aiAccountSettingsDescription)
            }

            switch settings.codexAccountProvider {
            case .chatGPTSubscription:
                ChatGPTAccountSettingsView()
            case .databricks:
                DatabricksAccountSettingsView()
            }
        }
        .formStyle(.grouped)
    }
}
