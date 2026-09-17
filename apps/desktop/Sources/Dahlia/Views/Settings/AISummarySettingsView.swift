import SwiftUI

/// Workspace model defaults; authentication remains specific to this Mac.
struct LocalSummarySettingsRows: View {
    var canEdit = true
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var catalog = CodexModelCatalog(service: .macInference)
    @State private var retryTask: Task<Void, Never>?

    var body: some View {
        Group {
            if catalog.isLoading {
                LabeledContent(L10n.model) { ProgressView().controlSize(.small) }
            }
            Picker(selection: modelSelection) {
                if !catalog.models.contains(where: { $0.model == workspaceSettings.summaryModelID }) {
                    Text(workspaceSettings.summaryModelID).tag(workspaceSettings.summaryModelID)
                }
                ForEach(catalog.models) { model in Text(model.displayName).tag(model.model) }
            } label: {
                Text(L10n.model)
                Text(L10n.codexModelDescription)
            }
            .pickerStyle(.menu)
            .disabled(!canEdit)

            Picker(selection: $workspaceSettings.summaryReasoningEffort) {
                if !catalog.effortOptions(modelID: workspaceSettings.summaryModelID)
                    .contains(where: { $0.reasoningEffort == workspaceSettings.summaryReasoningEffort }) {
                    Text(workspaceSettings.summaryReasoningEffort).tag(workspaceSettings.summaryReasoningEffort)
                }
                ForEach(catalog.effortOptions(modelID: workspaceSettings.summaryModelID)) { effort in
                    Text(effort.displayName).tag(effort.reasoningEffort)
                }
            } label: {
                Text(L10n.reasoningEffort)
                Text(L10n.reasoningEffortDescription)
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
            try await CodexRuntimeContextCoordinator.macInference.activate(provider: context)
        }
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { workspaceSettings.summaryModelID },
            set: { modelID in
                workspaceSettings.summaryModelID = modelID
                if let effort = catalog.resolvedEffort(current: workspaceSettings.summaryReasoningEffort, modelID: modelID) {
                    workspaceSettings.summaryReasoningEffort = effort
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
