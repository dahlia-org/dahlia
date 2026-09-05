import SwiftUI

struct AccountSettingsView: View {
    @Bindable private var vaultSettings = VaultAISettingsModel.shared
    @State private var chatGPTController = CodexAccountController()
    @State private var databricksController = DatabricksAccountController()

    var body: some View {
        switch vaultSettings.localProvider {
        case .chatGPTSubscription:
            ChatGPTAccountSettingsView(
                controller: chatGPTController,
                title: L10n.localAccountModelProvider,
                footer: localProviderFooter
            ) {
                providerPicker
            }
        case .databricks:
            DatabricksAccountSettingsView(
                controller: databricksController,
                title: L10n.localAccountModelProvider,
                footer: localProviderFooter
            ) {
                providerPicker
            }
        }

        if vaultSettings.isLocalAccount, let errorMessage = vaultSettings.errorMessage {
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
                || (vaultSettings.isLocalAccount && vaultSettings.isSwitchingRuntime)
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
