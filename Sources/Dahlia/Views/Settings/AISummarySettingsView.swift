import SwiftUI

/// 設定画面「AI 要約」タブ。LLM プロバイダーとモデル設定を管理する。
struct AISummarySettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var apiToken = ""
    @State private var isTestingConnection = false
    @State private var isLoadingDatabricksProfiles = false
    @State private var databricksProfiles: [DatabricksCLIClient.Profile] = []
    @State private var connectionTestResult: ConnectionTestResult?
    @State private var databricksProfileLoadError: String?
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

                if shouldShowAPITokenField {
                    LabeledContent {
                        SecureField("", text: $apiToken)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { settings.llmAPIToken = apiToken }
                    } label: {
                        Text(apiTokenLabel)
                        Text(L10n.apiTokenStoredInKeychain)
                    }
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
            if shouldLoadDatabricksProfiles {
                await loadDatabricksProfiles()
            }
        }
        .onDisappear {
            settings.llmAPIToken = apiToken
        }
        .onChange(of: settings.llmProviderRawValue) { _, _ in
            connectionTestResult = nil
            if shouldLoadDatabricksProfiles {
                Task { await loadDatabricksProfiles() }
            }
        }
        .onChange(of: settings.llmModelRawValue) { _, _ in
            connectionTestResult = nil
        }
        .onChange(of: settings.llmDatabricksProfile) { _, _ in
            connectionTestResult = nil
        }
        .onChange(of: settings.llmDatabricksAuthenticationTypeRawValue) { _, _ in
            connectionTestResult = nil
            if shouldLoadDatabricksProfiles {
                Task { await loadDatabricksProfiles() }
            } else {
                databricksProfileLoadError = nil
            }
        }
    }

    // MARK: - Private

    private var isLLMConfigComplete: Bool {
        guard settings.resolvedLLMEndpointURL.nilIfBlank != nil else { return false }

        switch settings.llmProvider {
        case .openAI:
            return apiToken.nilIfBlank != nil
        case .databricks:
            switch settings.llmDatabricksAuthenticationType {
            case .personalAccessToken:
                return apiToken.nilIfBlank != nil
            case .oauthCLI:
                return databricksProfiles.contains { $0.name == settings.llmDatabricksProfile }
            }
        }
    }

    private var shouldShowAPITokenField: Bool {
        switch settings.llmProvider {
        case .openAI:
            true
        case .databricks:
            settings.llmDatabricksAuthenticationType == .personalAccessToken
        }
    }

    private var shouldLoadDatabricksProfiles: Bool {
        settings.llmProvider == .databricks
            && settings.llmDatabricksAuthenticationType == .oauthCLI
    }

    private var apiTokenLabel: String {
        settings.llmProvider == .databricks ? L10n.personalAccessToken : L10n.apiToken
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

            Picker(selection: $settings.llmDatabricksAuthenticationType) {
                ForEach(DatabricksAuthenticationType.allCases) { authenticationType in
                    Text(authenticationType.displayName).tag(authenticationType)
                }
            } label: {
                Text(L10n.authenticationType)
                Text(L10n.databricksAuthenticationTypeDescription)
            }
            .pickerStyle(.menu)

            if settings.llmDatabricksAuthenticationType == .oauthCLI {
                LabeledContent {
                    HStack {
                        if isLoadingDatabricksProfiles {
                            ProgressView()
                                .controlSize(.small)
                        } else if databricksProfiles.isEmpty {
                            Text(L10n.noDatabricksProfiles)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("", selection: $settings.llmDatabricksProfile) {
                                ForEach(databricksProfiles) { profile in
                                    Text(profile.name).tag(profile.name)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        Button(L10n.refreshDatabricksProfiles, systemImage: "arrow.clockwise") {
                            Task { await loadDatabricksProfiles() }
                        }
                        .labelStyle(.iconOnly)
                        .disabled(isLoadingDatabricksProfiles)
                    }
                } label: {
                    Text(L10n.databricksProfile)
                    Text(L10n.databricksProfileDescription)
                }

                if let databricksProfileLoadError {
                    SettingsStatusMessage(
                        text: databricksProfileLoadError,
                        systemImage: "xmark.circle.fill",
                        tint: .red
                    )
                }
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
        if shouldShowAPITokenField {
            settings.llmAPIToken = apiToken
        }
        connectionTestResult = nil
        isTestingConnection = true
        Task {
            do {
                let token = try await LLMCredentialResolver().accessToken(
                    provider: settings.llmProvider,
                    apiToken: apiToken,
                    databricksAuthenticationType: settings.llmDatabricksAuthenticationType,
                    databricksProfile: settings.llmDatabricksProfile
                )
                try await LLMService.testConnection(
                    endpoint: settings.resolvedLLMEndpointURL,
                    model: settings.resolvedLLMModelName,
                    token: token
                )
                connectionTestResult = .success
            } catch {
                connectionTestResult = .failure(error.localizedDescription)
            }
            isTestingConnection = false
        }
    }

    private func loadDatabricksProfiles() async {
        isLoadingDatabricksProfiles = true
        databricksProfileLoadError = nil
        defer { isLoadingDatabricksProfiles = false }

        do {
            let profiles = try await DatabricksCLIClient().profiles()
            databricksProfiles = profiles
            let selectedProfile = AppSettings.resolvedDatabricksProfileSelection(
                current: settings.llmDatabricksProfile,
                availableProfiles: profiles.map(\.name)
            )
            if selectedProfile != settings.llmDatabricksProfile {
                settings.llmDatabricksProfile = selectedProfile
            }
        } catch {
            databricksProfiles = []
            databricksProfileLoadError = error.localizedDescription
        }
    }
}
