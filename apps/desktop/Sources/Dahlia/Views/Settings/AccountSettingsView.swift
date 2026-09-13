import SwiftUI

struct AccountSettingsView: View {
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var chatGPTController = CodexAccountController()
    @State private var databricksController = DatabricksAccountController()

    var body: some View {
        switch workspaceSettings.localProvider {
        case .chatGPTSubscription:
            ChatGPTAccountSettingsView(
                controller: chatGPTController,
                title: L10n.modelProvider,
                footer: localProviderDescription
            ) {
                providerPicker
            }
        case .databricks:
            DatabricksAccountSettingsView(
                controller: databricksController,
                title: L10n.modelProvider,
                footer: localProviderDescription
            ) {
                providerPicker
            }
        }

        if workspaceSettings.isLocalAccount, let errorMessage = workspaceSettings.errorMessage {
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
            selection: $workspaceSettings.localProvider,
            options: AIAccountProvider.allCases,
            label: \.displayName
        )
        .disabled(
            chatGPTController.isBusy
                || databricksController.isBusy
                || (workspaceSettings.isLocalAccount && workspaceSettings.isSwitchingRuntime)
        )
    }

    private var localProviderDescription: String {
        switch workspaceSettings.localProvider {
        case .chatGPTSubscription:
            L10n.codexAccountDescription
        case .databricks:
            L10n.databricksCodexDescription
        }
    }
}
