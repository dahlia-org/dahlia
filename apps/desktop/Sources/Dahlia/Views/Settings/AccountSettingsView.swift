import SwiftUI

struct AccountSettingsView: View {
    @Bindable private var vaultSettings = VaultAISettingsModel.shared
    @State private var dahliaController = DahliaCloudAccountController.shared
    @State private var chatGPTController = CodexAccountController()
    @State private var databricksController = DatabricksAccountController()

    var body: some View {
        Form {
            Section {
                if vaultSettings.isLocalAccount {
                    DahliaMenuPicker(
                        title: L10n.provider,
                        description: L10n.aiAccountDescription,
                        selection: $vaultSettings.localProvider,
                        options: AIAccountProvider.allCases,
                        label: \.displayName
                    )
                    .disabled(
                        chatGPTController.isBusy
                            || databricksController.isBusy
                            || vaultSettings.isSwitchingRuntime
                    )
                } else {
                    LabeledContent(L10n.provider, value: L10n.dahliaAccount)
                }

                LabeledContent(L10n.codexVersion, value: CodexBundle.version)
            } header: {
                Text(L10n.modelProvider)
            } footer: {
                Text(L10n.aiAccountSettingsDescription)
            }

            if vaultSettings.isLocalAccount {
                switch vaultSettings.localProvider {
                case .chatGPTSubscription:
                    ChatGPTAccountSettingsView(controller: chatGPTController)
                case .databricks:
                    DatabricksAccountSettingsView(controller: databricksController)
                }
            } else if let connectionID = vaultSettings.accountConnectionID,
                      let connection = dahliaController.connections.first(where: { $0.id == connectionID }) {
                Section {
                    SettingsStatusMessage(
                        text: connection.isSignedIn ? connection.origin : L10n.signInRequired,
                        systemImage: connection.isSignedIn ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tint: connection.isSignedIn ? .green : .orange
                    )
                } header: {
                    Text(connection.displayName)
                }
            }

            if let errorMessage = vaultSettings.errorMessage {
                Section {
                    SettingsStatusMessage(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}
