import SwiftUI

struct ServerSummarySettingsSection: View {
    let connectionID: UUID
    @Bindable private var model = ServerAccountSettingsModel.shared
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var isExpanded = false
    @State private var isHeaderHovered = false
    private var state: ServerAccountSettingsModel.State { model.state(for: connectionID) }
    private var remote: WorkspaceGenerationSettings.RemoteProcessing { workspaceSettings.generationSettings.processing.remote }
    private var usesLocalTranscription: Bool { workspaceSettings.generationSettings.processing.location == .local }
    private var customizableSummary: Bool { usesLocalTranscription || remote.workflow == .combined }
    private var summaryAvailable: Bool { !state.summaryMethods.isEmpty }
    private var models: [ServerSummaryService.Model] {
        state.summaryModels.filter { $0.supportsSummary(method: usesLocalTranscription ? "transcript" : "audio") }
    }

    private var selectedModel: ServerSummaryService.Model? {
        models.first { $0.id == remote.summaryModel || remote.summaryModel?.hasSuffix("." + $0.id) == true }
    }

    private var efforts: [String] { selectedModel?.supportedReasoningLevels.map(\.effort) ?? [] }

    var body: some View {
        Section {
            if state.isModelCatalogLoaded, customizableSummary, remote.summaryModel != nil, selectedModel == nil {
                SettingsStatusMessage(text: L10n.settingsCheckAdvancedModels, systemImage: "exclamationmark.triangle", tint: .orange)
            }
            Button {
                isExpanded.toggle()
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .accessibilityHidden(true)
                    Text(L10n.serverProcessingAdvanced)
                        .bold()
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isHeaderHovered ? DahliaDesign.contentHighlightColor : .clear,
                    in: .rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
                )
                .contentShape(.rect(cornerRadius: DahliaDesign.Highlight.compactCornerRadius))
                .onHover { isHeaderHovered = $0 }
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)

            if isExpanded {
                if !usesLocalTranscription {
                    Picker(L10n.processingWorkflow, selection: workflowSelection) {
                        Text(L10n.transcribeThenSummarize).tag(WorkspaceGenerationSettings.Workflow.transcribeThenSummarize)
                        Text(L10n.combinedTranscriptionSummary).tag(WorkspaceGenerationSettings.Workflow.combined)
                    }
                    .disabled(!summaryAvailable)
                    Text(remote.workflow == .combined
                        ? L10n.combinedTranscriptionSummaryDescription
                        : L10n.transcribeThenSummarizeDescription)
                        .foregroundStyle(.secondary)
                }
                if customizableSummary {
                    Picker(L10n.summaryModel, selection: summaryModelSelection) {
                        Text(L10n.automaticModelPreference).tag("")
                        if let saved = remote.summaryModel, selectedModel == nil {
                            Text(state.isModelCatalogLoaded ? "\(saved) — \(L10n.unavailableModelPreference)" : saved).tag(saved)
                        }
                        ForEach(models) { Text($0.displayName).tag($0.id) }
                    }
                    .disabled(!summaryAvailable || !state.isModelCatalogLoaded)
                    Picker(L10n.reasoningEffort, selection: effortSelection) {
                        Text(L10n.automaticModelPreference).tag("")
                        if let saved = remote.reasoningEffort, !efforts.contains(saved) {
                            Text(state.isModelCatalogLoaded ? "\(saved) — \(L10n.checkModelPreference)" : saved).tag(saved)
                        }
                        ForEach(efforts, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(!summaryAvailable || !state.isModelCatalogLoaded)
                    if let error = state.modelErrorMessage {
                        SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red)
                    } else if state.isModelCatalogLoaded, models.isEmpty {
                        Text(L10n.serverSummaryNoModels).foregroundStyle(.secondary)
                    }
                    Button(L10n.serverSummaryReloadModels) { model.refresh(connectionID: connectionID, reloadModels: true) }
                        .disabled(!summaryAvailable)
                    Text(L10n.automaticModelPreferenceDescription).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(AppSettings.shared.currentWorkspace?.allowsWorkspaceManagement != true)
    }

    private var workflowSelection: Binding<WorkspaceGenerationSettings.Workflow> {
        Binding(get: { remote.workflow }, set: { workspaceSettings.generationSettings.processing.remote.workflow = $0 })
    }

    private var summaryModelSelection: Binding<String> {
        Binding(
            get: { selectedModel?.id ?? remote.summaryModel ?? "" },
            set: { workspaceSettings.generationSettings.processing.remote.summaryModel = $0.nilIfBlank }
        )
    }

    private var effortSelection: Binding<String> {
        Binding(
            get: { remote.reasoningEffort ?? "" },
            set: { workspaceSettings.generationSettings.processing.remote.reasoningEffort = $0.nilIfBlank }
        )
    }

}
