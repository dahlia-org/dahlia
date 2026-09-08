import SwiftUI

struct ServerSummarySettingsSection: View {
    let connectionID: UUID
    @Bindable private var model = ServerAccountSettingsModel.shared
    private var state: ServerAccountSettingsModel.State { model.state(for: connectionID) }
    private var method: String { state.settings?.summary?.method ?? "transcript" }
    private var methods: [String] { state.summaryMethods.filter { $0 == "transcript" || $0 == "audio" } }
    private var settings: ServerAccountSettings.TranscriptSummary {
        state.settings?.summary?.selectedSettings ?? .init(model: method == "audio" ? "gemini-3-8-flash" : "gpt-5.4")
    }

    private var models: [ServerSummaryService.Model] {
        state.summaryModels.filter { method != "audio" || $0.supportsAudioSummary }
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
                        Text(method == "audio" ? L10n.serverSummaryAudio : L10n.serverSummaryTranscript).tag(method)
                    }
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
                Button(L10n.serverSummaryReloadModels) { model.refresh(connectionID: connectionID) }
                Picker(L10n.reasoningEffort, selection: Binding(
                    get: { efforts.contains(settings.reasoningEffort) ? settings.reasoningEffort : "" },
                    set: { save(.init(reasoningEffort: $0)) }
                )) {
                    if !efforts.contains(settings.reasoningEffort) { Text(L10n.reasoningEffort).tag("") }
                    ForEach(efforts, id: \.self) { Text($0).tag($0) }
                }
                .disabled(efforts.isEmpty)
                Picker(L10n.summaryDetailLevel, selection: Binding(
                    get: { settings.detail },
                    set: { save(.init(detail: $0)) }
                )) {
                    ForEach(SummaryDetailLevel.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            } else {
                Text(L10n.serverSummaryUnavailable).foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.summary)
        } footer: {
            Text(L10n.serverSummaryDescription)
        }
        .disabled(!state.canEdit)
    }

    private func save(_ settings: ServerAccountSettings.Patch.Transcript) {
        let patch: ServerAccountSettings.Patch.MethodSettings
        switch method {
        case "transcript": patch = .init(transcript: settings)
        case "audio": patch = .init(audio: settings)
        default: return
        }
        model.save(.init(summary: .init(methodSettings: patch)), connectionID: connectionID)
    }
}
