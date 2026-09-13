import SwiftUI

/// Device-local model preferences; output style and language belong to the selected account.
struct LocalSummarySettingsSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var catalog = CodexModelCatalog(service: .macInference)
    @State private var retryTask: Task<Void, Never>?

    var body: some View {
        Section {
            DisclosureGroup {
                if catalog.isLoading {
                    LabeledContent(L10n.model) { ProgressView().controlSize(.small) }
                } else if !catalog.models.isEmpty {
                    Picker(selection: modelSelection) {
                        if !catalog.models.contains(where: { $0.model == settings.codexModelID }) {
                            Text(settings.codexModelID).tag(settings.codexModelID)
                        }
                        ForEach(catalog.models) { model in Text(model.displayName).tag(model.model) }
                    } label: {
                        Text(L10n.model)
                        Text(L10n.codexModelDescription)
                    }
                    .pickerStyle(.menu)

                    Picker(selection: $settings.codexReasoningEffort) {
                        if !catalog.effortOptions(modelID: settings.codexModelID)
                            .contains(where: { $0.reasoningEffort == settings.codexReasoningEffort }) {
                            Text(settings.codexReasoningEffort).tag(settings.codexReasoningEffort)
                        }
                        ForEach(catalog.effortOptions(modelID: settings.codexModelID)) { effort in
                            Text(effort.displayName).tag(effort.reasoningEffort)
                        }
                    } label: {
                        Text(L10n.reasoningEffort)
                        Text(L10n.reasoningEffortDescription)
                    }
                    .pickerStyle(.menu)
                }

                if let errorMessage = catalog.errorMessage {
                    SettingsStatusMessage(text: errorMessage, systemImage: "exclamationmark.triangle.fill", tint: .red)
                }
                if catalog.canRetry { Button(L10n.retry, action: reload).disabled(catalog.isLoading) }

            } label: {
                LabeledContent(L10n.localModelPreferences, value: settings.codexModelID)
            }
        }
        .task(id: modelCatalogContext) { await loadModels(forceRefresh: true, context: modelCatalogContext) }
        .onDisappear { retryTask?.cancel() }
    }

    private func reload() {
        retryTask?.cancel()
        let context = modelCatalogContext
        retryTask = Task { await loadModels(forceRefresh: true, context: context) }
    }

    private func loadModels(forceRefresh: Bool, context: CodexRuntimeProvider) async {
        await catalog.load(forceRefresh: forceRefresh) {
            try await CodexRuntimeContextCoordinator.macInference.activate(provider: context)
        }
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { settings.codexModelID },
            set: { modelID in
                settings.codexModelID = modelID
                if let effort = catalog.resolvedEffort(current: settings.codexReasoningEffort, modelID: modelID) {
                    settings.codexReasoningEffort = effort
                }
            }
        )
    }

    private var modelCatalogContext: CodexRuntimeProvider {
        CodexRuntimeProvider(
            accountConnectionID: nil,
            localProvider: workspaceSettings.localProvider,
            databricksProfile: workspaceSettings.databricksProfile
        )
    }
}
