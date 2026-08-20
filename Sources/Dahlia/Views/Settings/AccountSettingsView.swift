import SwiftUI

struct AccountSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

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

                LabeledContent(L10n.codexVersion, value: CodexBundle.version)
            } header: {
                Text(L10n.modelProvider)
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
