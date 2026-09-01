import SwiftUI

struct AccountSettingsView: View {
    @Bindable private var vaultSettings = VaultAISettingsModel.shared
    @State private var dahliaController = DahliaCloudAccountController.shared
    @State private var chatGPTController = CodexAccountController()
    @State private var databricksController = DatabricksAccountController()

    var body: some View {
        if vaultSettings.isLocalAccount {
            switch vaultSettings.localProvider {
            case .chatGPTSubscription:
                ChatGPTAccountSettingsView(
                    controller: chatGPTController,
                    title: L10n.localAccount,
                    footer: localProviderFooter
                ) {
                    providerPicker
                }
            case .databricks:
                DatabricksAccountSettingsView(
                    controller: databricksController,
                    title: L10n.localAccount,
                    footer: localProviderFooter
                ) {
                    providerPicker
                }
            }
        } else {
            Section {
                LabeledContent(L10n.modelProvider, value: L10n.dahliaAccount)
            } header: {
                Text(L10n.dahliaAccount)
            }

            if let connectionID = vaultSettings.accountConnectionID,
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

    private var providerPicker: some View {
        DahliaMenuPicker(
            title: L10n.modelProvider,
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
    }

    private var localProviderFooter: String {
        "\(L10n.aiAccountSettingsDescription)\n\(localProviderDescription)"
    }

    private var localProviderDescription: String {
        switch vaultSettings.localProvider {
        case .chatGPTSubscription:
            L10n.codexAccountDescription
        case .databricks:
            L10n.databricksCodexDescription
        }
    }
}
