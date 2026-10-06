import SwiftUI

/// Device-local defaults for the selected account.
struct LocalSummarySettingsRows: View {
    enum Target {
        case summary, imageAnalysis, screenshotSelection
    }

    var canEdit = true
    /// Model and effort pairs that share one model catalog.
    var targets: [Target] = [.summary]
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var catalog = CodexModelCatalog(service: .shared)
    @State private var retryTask: Task<Void, Never>?

    var body: some View {
        Group {
            if catalog.isLoading {
                LabeledContent(L10n.model) { ProgressView().controlSize(.small) }
            }
            ForEach(targets, id: \.self) { target in
                Picker(selection: modelSelection(target)) {
                    let modelID = selectedModelID(target)
                    if !catalog.models.contains(where: { $0.model == modelID }) {
                        Text(modelID).tag(modelID)
                    }
                    ForEach(catalog.models.filter { target == .summary || $0.supportsImages }) { model in
                        Text(model.displayName).tag(model.model)
                    }
                } label: {
                    Text(target == .screenshotSelection ? L10n.screenshotSelectionModel : L10n.model)
                    Text(target == .screenshotSelection ? L10n.screenshotSelectionModelDescription : L10n.codexModelDescription)
                }
                .pickerStyle(.menu)
                .disabled(!canEdit)

                Picker(selection: effortSelection(target)) {
                    let effort = selectedReasoningEffort(target)
                    let options = catalog.effortOptions(modelID: selectedModelID(target))
                    if !options.contains(where: { $0.reasoningEffort == effort }) {
                        Text(effort).tag(effort)
                    }
                    ForEach(options) { effort in
                        Text(effort.displayName).tag(effort.reasoningEffort)
                    }
                } label: {
                    Text(target == .screenshotSelection ? L10n.screenshotSelectionReasoningEffort : L10n.reasoningEffort)
                    Text(reasoningEffortDescription(target))
                }
                .pickerStyle(.menu)
                .disabled(!canEdit)
            }

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

    private func reasoningEffortDescription(_ target: Target) -> String {
        switch target {
        case .summary: L10n.reasoningEffortDescription
        case .imageAnalysis: L10n.imageAnalysisReasoningEffortDescription
        case .screenshotSelection: L10n.screenshotSelectionReasoningEffortDescription
        }
    }

    private func selectedModelID(_ target: Target) -> String {
        let settings = workspaceSettings.generationSettings
        return switch target {
        case .summary: workspaceSettings.summaryModelID
        case .imageAnalysis: settings.imageAnalysis.model ?? CodexScreenshotAnalysisService.model
        case .screenshotSelection: settings.screenshotSelection.model ?? CodexScreenshotAnalysisService.model
        }
    }

    private func selectedReasoningEffort(_ target: Target) -> String {
        let settings = workspaceSettings.generationSettings
        return switch target {
        case .summary: workspaceSettings.summaryReasoningEffort
        case .imageAnalysis: settings.imageAnalysis.reasoningEffort ?? CodexScreenshotAnalysisService.reasoningEffort
        case .screenshotSelection: settings.screenshotSelection.reasoningEffort ?? SummaryScreenshotSelection.defaultReasoningEffort
        }
    }

    private func setModelID(_ modelID: String, for target: Target) {
        switch target {
        case .summary: workspaceSettings.summaryModelID = modelID
        case .imageAnalysis: workspaceSettings.generationSettings.imageAnalysis.model = modelID
        case .screenshotSelection: workspaceSettings.generationSettings.screenshotSelection.model = modelID
        }
    }

    private func setReasoningEffort(_ effort: String, for target: Target) {
        switch target {
        case .summary: workspaceSettings.summaryReasoningEffort = effort
        case .imageAnalysis: workspaceSettings.generationSettings.imageAnalysis.reasoningEffort = effort
        case .screenshotSelection: workspaceSettings.generationSettings.screenshotSelection.reasoningEffort = effort
        }
    }

    private func effortSelection(_ target: Target) -> Binding<String> {
        Binding(get: { selectedReasoningEffort(target) }, set: { setReasoningEffort($0, for: target) })
    }

    private func modelSelection(_ target: Target) -> Binding<String> {
        Binding(
            get: { selectedModelID(target) },
            set: { modelID in
                setModelID(modelID, for: target)
                if let effort = catalog.resolvedEffort(current: selectedReasoningEffort(target), modelID: modelID) {
                    setReasoningEffort(effort, for: target)
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
