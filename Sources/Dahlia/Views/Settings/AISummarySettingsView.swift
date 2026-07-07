import SwiftUI

/// 設定画面「AI 要約」タブ。LLM プロバイダーとモデル設定を管理する。
struct AISummarySettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var apiToken = ""
    @State private var isTestingConnection = false
    @State private var connectionTestResult: ConnectionTestResult?
    private enum ConnectionTestResult {
        case success
        case failure(String)
    }

    var body: some View {
        SettingsPage {
            SettingsSection(
                title: L10n.llmSettings,
                description: L10n.llmSettingsDescription
            ) {
                SettingsCard {
                    SettingsControlRow(
                        title: L10n.modelProvider,
                        description: L10n.modelProviderDescription
                    ) {
                        Picker(L10n.modelProvider, selection: $settings.llmProvider) {
                            ForEach(LLMProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220, alignment: .trailing)
                    }

                    Divider()

                    providerConfigurationRows

                    Divider()

                    SettingsControlRow(title: L10n.modelName) {
                        TextField(
                            "",
                            text: $settings.llmModelName,
                            prompt: Text(modelNamePrompt)
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    Divider()

                    SettingsControlRow(
                        title: L10n.apiToken,
                        description: L10n.apiTokenStoredInKeychain
                    ) {
                        SecureField("", text: $apiToken)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { settings.llmAPIToken = apiToken }
                    }
                }
            }

            SettingsSection(
                title: L10n.testConnection,
                description: L10n.connectionDiagnosticsDescription
            ) {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 16) {
                        if isTestingConnection {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(L10n.testing)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button(L10n.testConnection) {
                                testConnection()
                            }
                            .disabled(!isLLMConfigComplete)
                        }

                        if let result = connectionTestResult {
                            switch result {
                            case .success:
                                SettingsStatusMessage(
                                    text: L10n.connectionSuccess,
                                    systemImage: "checkmark.circle.fill",
                                    tint: .green
                                )
                            case let .failure(message):
                                SettingsStatusMessage(
                                    text: message,
                                    systemImage: "xmark.circle.fill",
                                    tint: .red
                                )
                            }
                        } else if !isLLMConfigComplete {
                            Text(L10n.llmConfigIncomplete)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .task {
            apiToken = settings.llmAPIToken
        }
        .onDisappear {
            settings.llmAPIToken = apiToken
        }
        .onChange(of: settings.llmProviderRawValue) { _, _ in
            connectionTestResult = nil
        }
    }

    // MARK: - Private

    private var isLLMConfigComplete: Bool {
        settings.resolvedLLMEndpointURL.nilIfBlank != nil && settings.llmModelName.nilIfBlank != nil && apiToken.nilIfBlank != nil
    }

    @ViewBuilder
    private var providerConfigurationRows: some View {
        switch settings.llmProvider {
        case .openAI:
            SettingsControlRow(
                title: L10n.endpointURL,
                description: L10n.openAIEndpointDescription
            ) {
                endpointPreview(settings.resolvedLLMEndpointURL)
            }
        case .databricks:
            SettingsControlRow(
                title: L10n.databricksWorkspaceID,
                description: L10n.databricksWorkspaceIDDescription
            ) {
                TextField(
                    "",
                    text: $settings.llmDatabricksWorkspaceID,
                    prompt: Text("1234567890123456")
                )
                .textFieldStyle(.roundedBorder)
            }

            Divider()

            SettingsControlRow(title: L10n.endpointURL) {
                endpointPreview(settings.resolvedLLMEndpointURL)
            }
        case .customEndpoint:
            SettingsControlRow(
                title: L10n.endpointURL,
                description: L10n.customEndpointDescription
            ) {
                TextField(
                    "",
                    text: $settings.llmEndpointURL,
                    prompt: Text("https://api.example.com/v1/chat/completions")
                )
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var modelNamePrompt: String {
        switch settings.llmProvider {
        case .openAI:
            "gpt-5"
        case .databricks:
            "databricks-gpt-5-4"
        case .customEndpoint:
            "gpt-5"
        }
    }

    private func endpointPreview(_ endpoint: String) -> some View {
        Text(endpoint.nilIfBlank ?? L10n.endpointGeneratedFromWorkspaceID)
            .font(.callout.monospaced())
            .foregroundStyle(endpoint.nilIfBlank == nil ? Color.secondary : Color.primary)
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func testConnection() {
        settings.llmAPIToken = apiToken
        connectionTestResult = nil
        isTestingConnection = true
        Task {
            do {
                try await LLMService.testConnection(
                    endpoint: settings.resolvedLLMEndpointURL,
                    model: settings.llmModelName,
                    token: apiToken
                )
                connectionTestResult = .success
            } catch {
                connectionTestResult = .failure(error.localizedDescription)
            }
            isTestingConnection = false
        }
    }
}
