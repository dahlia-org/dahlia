import SwiftUI

struct ServerSummarySettingsSection: View {
    let connectionID: UUID
    @Bindable private var model = ServerAccountSettingsModel.shared
    @Bindable private var workspaceSettings = WorkspaceAISettingsModel.shared
    @State private var isExpanded = false
    @State private var isHeaderHovered = false
    private var state: ServerAccountSettingsModel.State { model.state(for: connectionID) }
    private var remote: WorkspaceGenerationSettings.RemoteProcessing { workspaceSettings.generationSettings.processing.remote }
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
                Picker(L10n.processingWorkflow, selection: workflowSelection) {
                    Text(L10n.transcribeThenSummarize).tag(WorkspaceGenerationSettings.Workflow.transcribeThenSummarize)
                    Text(L10n.combinedTranscriptionSummary).tag(WorkspaceGenerationSettings.Workflow.combined)
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

    private var transcriptionModelSelection: Binding<String> {
        Binding(
            get: { selectedTranscriptionModel?.id ?? remote.transcriptionModel ?? "" },
            set: { workspaceSettings.generationSettings.processing.remote.transcriptionModel = $0.nilIfBlank }
        )
    }

}
