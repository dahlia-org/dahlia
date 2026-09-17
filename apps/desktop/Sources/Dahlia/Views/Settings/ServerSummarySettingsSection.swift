import SwiftUI

struct ServerSummarySettingsSection: View {
    let connectionID: UUID
    @Bindable private var model = ServerAccountSettingsModel.shared
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared
    private var state: ServerAccountSettingsModel.State { model.state(for: connectionID) }
    private var remote: WorkspaceGenerationSettings.RemoteProcessing { workspaceSettings.generationSettings.processing.remote }
    private var usesLocalTranscription: Bool { workspaceSettings.generationSettings.processing.location == .local }
    private var showsAudioSettings: Bool { !usesLocalTranscription }
    private var showsTranscriptSummarySettings: Bool { usesLocalTranscription || remote.workflow == .transcribeThenSummarize }
    private var summaryAvailable: Bool { !state.summaryMethods.isEmpty }

    private var audioModels: [ServerSummaryService.Model] {
        state.summaryModels.filter { $0.supportsSummary(method: "audio") }
    }

    private var transcriptModels: [ServerSummaryService.Model] {
        state.summaryModels.filter { $0.supportsSummary(method: "transcript") }
    }

    private var selectedAudioModel: ServerSummaryService.Model? {
        audioModels.first { $0.id == remote.summaryModel || remote.summaryModel?.hasSuffix("." + $0.id) == true }
    }

    private var transcriptSummaryModel: String? {
        remote.transcriptSummaryModel ?? (usesLocalTranscription ? remote.summaryModel : nil)
    }

    private var transcriptSummaryReasoningEffort: String? {
        remote.transcriptSummaryReasoningEffort ?? (usesLocalTranscription ? remote.reasoningEffort : nil)
    }

    private var selectedTranscriptModel: ServerSummaryService.Model? {
        transcriptModels.first { $0.id == transcriptSummaryModel || transcriptSummaryModel?.hasSuffix("." + $0.id) == true }
    }

    private var audioEfforts: [String] { selectedAudioModel?.supportedReasoningLevels.map(\.effort) ?? [] }
    private var transcriptEfforts: [String] { selectedTranscriptModel?.supportedReasoningLevels.map(\.effort) ?? [] }

    var body: some View {
        Group {
            if state.isModelCatalogLoaded,
               (showsAudioSettings && remote.summaryModel != nil && selectedAudioModel == nil)
               || (showsTranscriptSummarySettings && transcriptSummaryModel != nil && selectedTranscriptModel == nil) {
                SettingsStatusMessage(text: L10n.settingsCheckAdvancedModels, systemImage: "exclamationmark.triangle", tint: .orange)
            }
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
            if showsAudioSettings {
                Picker(L10n.audioProcessingModel, selection: audioModelSelection) {
                    Text(L10n.automaticModelPreference).tag("")
                    if let saved = remote.summaryModel, selectedAudioModel == nil {
                        Text(state.isModelCatalogLoaded ? "\(saved) — \(L10n.unavailableModelPreference)" : saved).tag(saved)
                    }
                    ForEach(audioModels) { Text($0.displayName).tag($0.id) }
                }
                .disabled(!summaryAvailable || !state.isModelCatalogLoaded)
                Picker(L10n.audioProcessingReasoningEffort, selection: audioEffortSelection) {
                    Text(L10n.automaticModelPreference).tag("")
                    if let saved = remote.reasoningEffort, !audioEfforts.contains(saved) {
                        Text(state.isModelCatalogLoaded ? "\(saved) — \(L10n.checkModelPreference)" : saved).tag(saved)
                    }
                    ForEach(audioEfforts, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!summaryAvailable || !state.isModelCatalogLoaded)
            }
            if showsTranscriptSummarySettings {
                Picker(L10n.summaryModel, selection: transcriptModelSelection) {
                    Text(L10n.automaticModelPreference).tag("")
                    if let saved = transcriptSummaryModel, selectedTranscriptModel == nil {
                        Text(state.isModelCatalogLoaded ? "\(saved) — \(L10n.unavailableModelPreference)" : saved).tag(saved)
                    }
                    ForEach(transcriptModels) { Text($0.displayName).tag($0.id) }
                }
                .disabled(!summaryAvailable || !state.isModelCatalogLoaded)
                Picker(L10n.summaryReasoningEffort, selection: transcriptEffortSelection) {
                    Text(L10n.automaticModelPreference).tag("")
                    if let saved = transcriptSummaryReasoningEffort, !transcriptEfforts.contains(saved) {
                        Text(state.isModelCatalogLoaded ? "\(saved) — \(L10n.checkModelPreference)" : saved).tag(saved)
                    }
                    ForEach(transcriptEfforts, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!summaryAvailable || !state.isModelCatalogLoaded)
            }
            if let error = state.modelErrorMessage {
                SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red)
            } else if state.isModelCatalogLoaded,
                      (showsAudioSettings && audioModels.isEmpty) || (showsTranscriptSummarySettings && transcriptModels.isEmpty) {
                Text(L10n.serverSummaryNoModels).foregroundStyle(.secondary)
            }
            Button(L10n.serverSummaryReloadModels) { model.refresh(connectionID: connectionID, reloadModels: true) }
                .disabled(!summaryAvailable)
        }
        .disabled(AppSettings.shared.currentWorkspace?.allowsWorkspaceManagement != true)
    }

    private var workflowSelection: Binding<WorkspaceGenerationSettings.Workflow> {
        Binding(get: { remote.workflow }, set: { workspaceSettings.generationSettings.processing.remote.workflow = $0 })
    }

    private var audioModelSelection: Binding<String> {
        Binding(
            get: { selectedAudioModel?.id ?? remote.summaryModel ?? "" },
            set: { workspaceSettings.generationSettings.processing.remote.summaryModel = $0.nilIfBlank }
        )
    }

    private var audioEffortSelection: Binding<String> {
        Binding(
            get: { remote.reasoningEffort ?? "" },
            set: { workspaceSettings.generationSettings.processing.remote.reasoningEffort = $0.nilIfBlank }
        )
    }

    private var transcriptModelSelection: Binding<String> {
        Binding(
            get: { selectedTranscriptModel?.id ?? transcriptSummaryModel ?? "" },
            set: { workspaceSettings.generationSettings.setTranscriptSummaryModel($0.nilIfBlank) }
        )
    }

    private var transcriptEffortSelection: Binding<String> {
        Binding(
            get: { transcriptSummaryReasoningEffort ?? "" },
            set: { workspaceSettings.generationSettings.setTranscriptSummaryReasoningEffort($0.nilIfBlank) }
        )
    }

}
