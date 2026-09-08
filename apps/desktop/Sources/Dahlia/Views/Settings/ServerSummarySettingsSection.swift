import SwiftUI

struct ServerSummarySettingsSection: View {
    let connectionID: UUID
    @Bindable private var model = ServerAccountSettingsModel.shared
    private var state: ServerAccountSettingsModel.State { model.state(for: connectionID) }
    private var settings: ServerAccountSettings.TranscriptSummary { state.settings?.summary?.methodSettings.transcript ?? .init() }

    private var selectedModel: ServerSummaryService.Model? {
        state.summaryModels.first { $0.id == settings.model || settings.model.hasSuffix("." + $0.id) }
    }

    private var efforts: [String] { selectedModel?.supportedReasoningLevels.map(\.effort) ?? [] }

    var body: some View {
        Section {
            if state.summaryMethods.contains("transcript") {
                Picker(L10n.serverSummaryMethod, selection: Binding(
                    get: { state.settings?.summary?.method ?? "transcript" },
                    set: { model.save(.init(summary: .init(method: $0)), connectionID: connectionID) }
                )) {
                    ForEach(state.summaryMethods, id: \.self) { method in
                        Text(L10n.serverSummaryTranscript).tag(method)
                    }
                }
                Picker(L10n.model, selection: Binding(
                    get: { selectedModel?.id ?? "" },
                    set: { value in
                        guard let selected = state.summaryModels.first(where: { $0.id == value }) else { return }
                        var next = settings
                        next.model = selected.id
                        if !selected.supportedReasoningLevels.contains(where: { $0.effort == next.reasoningEffort }) {
                            next.reasoningEffort = selected.defaultReasoningLevel ?? selected.supportedReasoningLevels.first?.effort ?? "none"
                        }
                        save(.init(model: next.model, reasoningEffort: next.reasoningEffort))
                    }
                )) {
                    if selectedModel == nil { Text(L10n.serverSummaryChooseModel).tag("") }
                    ForEach(state.summaryModels) { Text($0.displayName).tag($0.id) }
                }
                .disabled(state.summaryModels.isEmpty)
                if let error = state.modelErrorMessage {
                    Text(error).foregroundStyle(.red)
                } else if state.summaryModels.isEmpty {
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
        model.save(.init(summary: .init(methodSettings: .init(transcript: settings))), connectionID: connectionID)
    }
}
