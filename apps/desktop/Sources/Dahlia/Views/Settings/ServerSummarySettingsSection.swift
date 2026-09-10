import SwiftUI

struct ServerSummarySettingsSection: View {
    let connectionID: UUID
    @Bindable private var model = ServerAccountSettingsModel.shared
    private var state: ServerAccountSettingsModel.State { model.state(for: connectionID) }
    private var remote: ServerAccountSettings.RemoteProcessing { state.settings?.processing?.remote ?? .init() }
    private var transcribesFirst: Bool { remote.workflow == .transcribeThenSummarize }
    private var models: [ServerSummaryService.Model] {
        state.summaryModels.filter { $0.supportsSummary(method: transcribesFirst ? "transcript" : "audio") }
    }

    private var audioModels: [ServerSummaryService.Model] { state.summaryModels.filter(\.supportsAudioSummary) }
    private var selectedModel: ServerSummaryService.Model? {
        models.first { $0.id == remote.summaryModel || remote.summaryModel?.hasSuffix("." + $0.id) == true }
    }

    private var selectedTranscriptionModel: ServerSummaryService.Model? {
        audioModels.first { $0.id == remote.transcriptionModel || remote.transcriptionModel?.hasSuffix("." + $0.id) == true }
    }

    private var efforts: [String] { selectedModel?.supportedReasoningLevels.map(\.effort) ?? [] }

    var body: some View {
        Section {
            if state.modelErrorMessage == nil, !state.isLoading,
               (remote.summaryModel != nil && selectedModel == nil)
               || (transcribesFirst && remote.transcriptionModel != nil && selectedTranscriptionModel == nil) {
                SettingsStatusMessage(text: L10n.settingsCheckAdvancedModels, systemImage: "exclamationmark.triangle", tint: .orange)
            }
            DisclosureGroup(L10n.serverProcessingAdvanced) {
                Picker(L10n.processingWorkflow, selection: workflowSelection) {
                    Text(L10n.transcribeThenSummarize).tag(ServerAccountSettings.Workflow.transcribeThenSummarize)
                    Text(L10n.combinedTranscriptionSummary).tag(ServerAccountSettings.Workflow.combined)
                }
                Picker(L10n.summaryModel, selection: summaryModelSelection) {
                    Text(L10n.automaticModelPreference).tag("")
                    if let saved = remote.summaryModel, selectedModel == nil {
                        Text("\(saved) — \(L10n.unavailableModelPreference)").tag(saved)
                    }
                    ForEach(models) { Text($0.displayName).tag($0.id) }
                }
                Picker(L10n.reasoningEffort, selection: effortSelection) {
                    Text(L10n.automaticModelPreference).tag("")
                    if let saved = remote.reasoningEffort, !efforts.contains(saved) {
                        Text("\(saved) — \(L10n.checkModelPreference)").tag(saved)
                    }
                    ForEach(efforts, id: \.self) { Text($0).tag($0) }
                }
                if transcribesFirst {
                    Picker(L10n.transcriptionModel, selection: transcriptionModelSelection) {
                        Text(L10n.automaticModelPreference).tag("")
                        if let saved = remote.transcriptionModel, selectedTranscriptionModel == nil {
                            Text("\(saved) — \(L10n.unavailableModelPreference)").tag(saved)
                        }
                        ForEach(audioModels) { Text($0.displayName).tag($0.id) }
                    }
                }
                if let error = state.modelErrorMessage {
                    SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red)
                } else if models.isEmpty {
                    Text(L10n.serverSummaryNoModels).foregroundStyle(.secondary)
                }
                Button(L10n.serverSummaryReloadModels) { model.refresh(connectionID: connectionID, reloadModels: true) }
                Text(L10n.automaticModelPreferenceDescription).foregroundStyle(.secondary)
            }
        }
        .disabled(!state.canEdit)
    }

    private var workflowSelection: Binding<ServerAccountSettings.Workflow> {
        Binding(get: { remote.workflow }, set: { save(.init(workflow: $0)) })
    }

    private var summaryModelSelection: Binding<String> {
        Binding(
            get: { selectedModel?.id ?? remote.summaryModel ?? "" },
            set: { save(.init(summaryModel: .some($0.nilIfBlank))) }
        )
    }

    private var effortSelection: Binding<String> {
        Binding(
            get: { remote.reasoningEffort ?? "" },
            set: { save(.init(reasoningEffort: .some($0.nilIfBlank))) }
        )
    }

    private var transcriptionModelSelection: Binding<String> {
        Binding(
            get: { selectedTranscriptionModel?.id ?? remote.transcriptionModel ?? "" },
            set: { save(.init(transcriptionModel: .some($0.nilIfBlank))) }
        )
    }

    private func save(_ remote: ServerAccountSettings.Patch.Remote) {
        model.save(.init(processing: .init(remote: remote)), connectionID: connectionID)
    }
}
