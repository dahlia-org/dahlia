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
        Form {
            Section {
                Picker(selection: $settings.llmProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                } label: {
                    Text(L10n.modelProvider)
                    Text(L10n.modelProviderDescription)
                }
                .pickerStyle(.menu)

                Picker(selection: $settings.llmModel) {
                    ForEach(LLMModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                } label: {
                    Text(L10n.model)
                    Text(L10n.modelDescription)
                }
                .pickerStyle(.menu)

                providerConfigurationRows

                LabeledContent {
                    TextField("", value: $settings.llmMaxTokens, format: .number)
                        .textFieldStyle(.roundedBorder)
                } label: {
                    Text(L10n.maxTokens)
                    Text(L10n.maxTokensDescription)
                }

                LabeledContent {
                    SecureField("", text: $apiToken)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { settings.llmAPIToken = apiToken }
                } label: {
                    Text(L10n.apiToken)
                    Text(L10n.apiTokenStoredInKeychain)
                }
            } header: {
                Text(L10n.llmSettings)
            } footer: {
                Text(L10n.llmSettingsDescription)
            }

            Section {
                connectionTestControl
                connectionTestStatus
            } header: {
                Text(L10n.testConnection)
            } footer: {
                Text(L10n.connectionDiagnosticsDescription)
            }
        }
        .formStyle(.grouped)
        .task {
            apiToken = settings.llmAPIToken
        }
        .onDisappear {
            settings.llmAPIToken = apiToken
        }
        .onChange(of: settings.llmProviderRawValue) { _, _ in
            connectionTestResult = nil
        }
        .onChange(of: settings.llmModelRawValue) { _, _ in
            connectionTestResult = nil
        }
    }

    // MARK: - Private

    private var isLLMConfigComplete: Bool {
        settings.resolvedLLMEndpointURL.nilIfBlank != nil && apiToken.nilIfBlank != nil
    }

    @ViewBuilder
    private var connectionTestControl: some View {
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
    }

    @ViewBuilder
    private var connectionTestStatus: some View {
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
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var providerConfigurationRows: some View {
        switch settings.llmProvider {
        case .openAI:
            LabeledContent {
                endpointPreview(settings.resolvedLLMEndpointURL)
            } label: {
                Text(L10n.endpointURL)
                Text(L10n.openAIEndpointDescription)
            }
        case .databricks:
            LabeledContent {
                TextField(
                    "",
                    text: $settings.llmDatabricksWorkspaceID,
                    prompt: Text("1234567890123456")
                )
                .textFieldStyle(.roundedBorder)
            } label: {
                Text(L10n.databricksWorkspaceID)
                Text(L10n.databricksWorkspaceIDDescription)
            }

            LabeledContent(L10n.endpointURL) {
                endpointPreview(settings.resolvedLLMEndpointURL)
            }
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
                    model: settings.resolvedLLMModelName,
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
