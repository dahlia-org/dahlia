import SwiftUI

struct ServerSummarySettingsSection: View {
    let connectionID: UUID
    @Bindable private var model = ServerAccountSettingsModel.shared
    private var state: ServerAccountSettingsModel.State { model.state(for: connectionID) }
    private var method: String { state.settings?.summary?.method ?? "transcript" }
    private var methods: [String] {
        state.recordingProcessingMethods.map(\.rawValue)
    }

    private var settings: ServerAccountSettings.SummaryModelSettings {
        state.settings?.summary?.selectedSettings ?? .init(model: method == "audio" ? "gemini-3-8-flash" : "gpt-5.4")
    }

    private var models: [ServerSummaryService.Model] {
        state.summaryModels.filter { $0.supportsStructuredSummary && (method != "audio" || $0.supportsAudioSummary) }
    }

    private var selectedModel: ServerSummaryService.Model? {
        models.first { $0.id == settings.model || settings.model.hasSuffix("." + $0.id) }
    }

    private var efforts: [String] { selectedModel?.supportedReasoningLevels.map(\.effort) ?? [] }

    var body: some View {
        Section {
            if !methods.isEmpty {
                Picker(L10n.serverSummaryMethod, selection: Binding(
                    get: { method },
                    set: { model.save(.init(summary: .init(method: $0)), connectionID: connectionID) }
                )) {
                    ForEach(methods, id: \.self) { method in
                        Text((RecordingProcessingMethod(rawValue: method) ?? .transcript).displayName).tag(method)
                    }
                }
                Picker(L10n.summaryDetailLevel, selection: Binding(
                    get: { state.settings?.summary?.detail ?? "high" },
                    set: { model.save(.init(summary: .init(detail: $0)), connectionID: connectionID) }
                )) {
                    ForEach(SummaryDetailLevel.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Picker(L10n.model, selection: Binding(
                    get: { selectedModel?.id ?? "" },
                    set: { value in
                        guard let selected = models.first(where: { $0.id == value }) else { return }
                        var next = settings
                        next.model = selected.id
                        if !selected.supportedReasoningLevels.contains(where: { $0.effort == next.reasoningEffort }) {
                            next.reasoningEffort = selected.defaultReasoningLevel ?? selected.supportedReasoningLevels.first?.effort ?? "none"
                        }
                        save(.init(model: next.model, reasoningEffort: next.reasoningEffort))
                    }
                )) {
                    if selectedModel == nil { Text(L10n.serverSummaryChooseModel).tag("") }
                    ForEach(models) { Text($0.displayName).tag($0.id) }
                }
                .disabled(models.isEmpty)
                if let error = state.modelErrorMessage {
                    Text(error).foregroundStyle(.red)
                } else if models.isEmpty {
                    Text(L10n.serverSummaryNoModels).foregroundStyle(.secondary)
                }
                Picker(L10n.reasoningEffort, selection: Binding(
                    get: { efforts.contains(settings.reasoningEffort) ? settings.reasoningEffort : "" },
                    set: { save(.init(reasoningEffort: $0)) }
                )) {
                    if !efforts.contains(settings.reasoningEffort) { Text(L10n.reasoningEffort).tag("") }
                    ForEach(efforts, id: \.self) { Text($0).tag($0) }
                }
                .disabled(efforts.isEmpty)
                if method == "cloudTranscription" {
                    Picker(L10n.transcriptionModel, selection: Binding(
                        get: { state.settings?.summary?.methodSettings.audio?.model ?? "gemini-3-8-flash" },
                        set: { value in
                            guard let selected = state.summaryModels.first(where: {
                                $0.id == value && $0.supportsAudioSummary && $0.supportsStructuredSummary
                            }) else { return }
                            model.save(.init(summary: .init(methodSettings: .init(audio: .init(
                                model: value,
                                reasoningEffort: selected.defaultReasoningLevel ?? "medium"
                            )))), connectionID: connectionID)
                        }
                    )) {
                        ForEach(state.summaryModels.filter { $0.supportsAudioSummary && $0.supportsStructuredSummary }) {
                            Text($0.displayName).tag($0.id)
                        }
                    }
                }
            } else {
                Text(L10n.serverSummaryUnavailable).foregroundStyle(.secondary)
            }
            Button(L10n.serverSummaryReloadModels) { model.refresh(connectionID: connectionID, reloadModels: true) }
        } header: {
            Text(L10n.summary)
        } footer: {
            Text(L10n.serverSummaryDescription)
        }
        .disabled(!state.canEdit)
    }

    private func save(_ settings: ServerAccountSettings.Patch.ModelSettings) {
        let patch: ServerAccountSettings.Patch.MethodSettings
        switch method {
        case "transcript", "cloudTranscription": patch = .init(transcript: settings)
        case "audio": patch = .init(audio: settings)
        default: return
        }
        model.save(.init(summary: .init(methodSettings: patch)), connectionID: connectionID)
    }
}
