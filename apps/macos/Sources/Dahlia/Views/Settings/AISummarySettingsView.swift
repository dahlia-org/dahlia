import SwiftUI

/// Device-local defaults for the selected account.
struct LocalSummarySettingsRows: View {
    var canEdit = true
    var imageAnalysis = false
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var catalog = CodexModelCatalog(service: .shared)
    @State private var retryTask: Task<Void, Never>?

    var body: some View {
        Group {
            if catalog.isLoading {
                LabeledContent(L10n.model) { ProgressView().controlSize(.small) }
            }
            Picker(selection: modelSelection) {
                if !catalog.models.contains(where: { $0.model == selectedModelID }) {
                    Text(selectedModelID).tag(selectedModelID)
                }
                ForEach(catalog.models.filter { !imageAnalysis || $0.supportsImages }) { model in Text(model.displayName).tag(model.model) }
            } label: {
                Text(L10n.model)
                Text(L10n.codexModelDescription)
            }
            .pickerStyle(.menu)
            .disabled(!canEdit)

            Picker(selection: effortSelection) {
                if !catalog.effortOptions(modelID: selectedModelID)
                    .contains(where: { $0.reasoningEffort == selectedReasoningEffort }) {
                    Text(selectedReasoningEffort).tag(selectedReasoningEffort)
                }
                ForEach(catalog.effortOptions(modelID: selectedModelID)) { effort in
                    Text(effort.displayName).tag(effort.reasoningEffort)
                }
            } label: {
                Text(L10n.reasoningEffort)
                Text(imageAnalysis ? L10n.imageAnalysisReasoningEffortDescription : L10n.reasoningEffortDescription)
            }
            .pickerStyle(.menu)
            .disabled(!canEdit)

            if let errorMessage = catalog.errorMessage {
                SettingsStatusMessage(text: errorMessage, systemImage: "exclamationmark.triangle.fill", tint: .red)
            }
            if catalog.canRetry { Button(L10n.retry, action: reload).disabled(catalog.isLoading) }
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
            guard await workspaceSettings.waitForRuntimeContext(),
                  CodexRuntimeContextStore.shared.provider == context else { throw CodexConfigurationError.accountNotReady }
        }
    }

    private var selectedModelID: String {
        get {
            if imageAnalysis {
                return workspaceSettings.generationSettings.imageAnalysis.model ?? CodexScreenshotAnalysisService.model
            }
            return workspaceSettings.summaryModelID
        }
        nonmutating set {
            if imageAnalysis {
                workspaceSettings.generationSettings.imageAnalysis.model = newValue
            } else {
                workspaceSettings.summaryModelID = newValue
            }
        }
    }

    private var selectedReasoningEffort: String {
        get {
            if imageAnalysis {
                return workspaceSettings.generationSettings.imageAnalysis.reasoningEffort ?? CodexScreenshotAnalysisService.reasoningEffort
            }
            return workspaceSettings.summaryReasoningEffort
        }
        nonmutating set {
            if imageAnalysis {
                workspaceSettings.generationSettings.imageAnalysis.reasoningEffort = newValue
            } else {
                workspaceSettings.summaryReasoningEffort = newValue
            }
        }
    }

    private var effortSelection: Binding<String> {
        Binding(get: { selectedReasoningEffort }, set: { selectedReasoningEffort = $0 })
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { selectedModelID },
            set: { modelID in
                selectedModelID = modelID
                if let effort = catalog.resolvedEffort(current: selectedReasoningEffort, modelID: modelID) {
                    selectedReasoningEffort = effort
                }
            }
        )
    }

    private var modelCatalogContext: CodexRuntimeProvider {
        CodexRuntimeProvider(
            accountConnectionID: workspaceSettings.accountConnectionID,
            localProvider: workspaceSettings.localProvider,
            databricksProfile: workspaceSettings.databricksProfile
        )
    }
}
