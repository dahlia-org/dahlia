import SwiftUI

/// Local Account settings used whenever processing is local, including Server vaults.
struct LocalSummarySettingsSection: View {
    @ObservedObject private var settings = AppSettings.shared
    @Bindable private var vaultSettings = VaultAISettingsModel.shared
    @State private var catalog = CodexModelCatalog()
    @State private var retryTask: Task<Void, Never>?
    @State private var preservesEffortForNextModelChange = false

    var body: some View {
        Section {
            if catalog.isLoading {
                LabeledContent(L10n.model) { ProgressView().controlSize(.small) }
            } else if !catalog.models.isEmpty {
                Picker(selection: modelSelection) {
                    ForEach(catalog.models) { model in Text(model.displayName).tag(model.model) }
                } label: {
                    Text(L10n.model)
                    Text(L10n.codexModelDescription)
                }
                .pickerStyle(.menu)

                Picker(selection: $settings.codexReasoningEffort) {
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

            Picker(selection: $settings.summaryDetailLevel) {
                ForEach(SummaryDetailLevel.allCases) { level in Text(level.displayName).tag(level) }
            } label: {
                Text(L10n.summaryDetailLevel)
                Text(L10n.summaryDetailLevelDescription)
            }
            .pickerStyle(.menu)

            Picker(selection: $settings.llmSummaryLanguage) {
                ForEach(SummaryLanguage.allCases) { language in Text(language.displayName).tag(language) }
            } label: {
                Text(L10n.summaryOutputLanguage)
                Text(L10n.summaryOutputLanguageDescription)
            }
            .pickerStyle(.menu)
        } header: {
            Text(L10n.localProcessing)
        } footer: {
            Text(L10n.localProcessingDescription)
        }
        .task(id: modelCatalogContext) { await loadModels(forceRefresh: true, context: modelCatalogContext) }
        .onChange(of: settings.codexModelID) {
            if preservesEffortForNextModelChange { preservesEffortForNextModelChange = false } else { resolveEffortSelection() }
        }
        .onDisappear { retryTask?.cancel() }
    }

    private func reload() {
        retryTask?.cancel()
        let context = modelCatalogContext
        retryTask = Task { await loadModels(forceRefresh: true, context: context) }
    }

    private func loadModels(forceRefresh: Bool, context: ModelCatalogContext) async {
        await catalog.load(forceRefresh: forceRefresh)
        guard context == modelCatalogContext, !catalog.models.isEmpty else { return }
        if let selection = catalog.selectionToPersist(current: settings.codexModelID) {
            preservesEffortForNextModelChange = true
            settings.codexModelID = selection
        }
        resolveEffortSelection()
    }

    private func resolveEffortSelection() {
        guard let effort = catalog.resolvedEffort(current: settings.codexReasoningEffort, modelID: settings.codexModelID) else { return }
        settings.codexReasoningEffort = effort
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { catalog.resolvedSelection(current: settings.codexModelID) ?? settings.codexModelID },
            set: { settings.codexModelID = $0 }
        )
    }

    private var modelCatalogContext: ModelCatalogContext {
        ModelCatalogContext(
            vaultID: vaultSettings.vaultID,
            provider: CodexRuntimeProvider(
                accountConnectionID: vaultSettings.accountConnectionID,
                localProvider: vaultSettings.localProvider,
                databricksProfile: vaultSettings.databricksProfile
            )
        )
    }

    private struct ModelCatalogContext: Hashable {
        let vaultID: UUID?
        let provider: CodexRuntimeProvider
    }
}
