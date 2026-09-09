import SwiftUI

struct ServerSummarySettingsSection: View {
    let connectionID: UUID
    @Bindable private var model = ServerAccountSettingsModel.shared
    private var state: ServerAccountSettingsModel.State { model.state(for: connectionID) }
    private var remote: ServerAccountSettings.RemoteSummarySettings {
        state.settings?.summary?.remote ?? .init(transcriptionModel: "gemini-3-8-flash")
    }

    private var transcribesFirst: Bool { remote.transcriptionModel != nil }
    private var models: [ServerSummaryService.Model] {
        summaryModels(transcribingFirst: transcribesFirst)
    }

    private var audioModels: [ServerSummaryService.Model] { state.summaryModels.filter(\.supportsAudioSummary) }
    private var selectedModel: ServerSummaryService.Model? {
        models.first { $0.id == remote.model || remote.model.hasSuffix("." + $0.id) }
    }

    private var efforts: [String] { selectedModel?.supportedReasoningLevels.map(\.effort) ?? [] }

    var body: some View {
        Section {
            Toggle(L10n.transcribeBeforeSummary, isOn: Binding(
                get: { transcribesFirst },
                set: { setTranscribesFirst($0) }
            ))
            .toggleStyle(.switch)
            .disabled(audioModels.isEmpty)

            Picker(L10n.summaryDetailLevel, selection: Binding(
                get: { remote.detail },
                set: { model.save(.init(summary: .init(remote: .init(detail: $0))), connectionID: connectionID) }
            )) {
                ForEach(SummaryDetailLevel.allCases) { Text($0.displayName).tag($0.rawValue) }
            }

            Picker(L10n.model, selection: Binding(
                get: { selectedModel?.id ?? "" },
                set: { selectModel($0) }
            )) {
                if selectedModel == nil { Text(L10n.serverSummaryChooseModel).tag("") }
                ForEach(models) { Text($0.displayName).tag($0.id) }
            }
            .disabled(models.isEmpty)

            if let error = state.modelErrorMessage {
                SettingsStatusMessage(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red)
            } else if models.isEmpty {
                Text(L10n.serverSummaryNoModels).foregroundStyle(.secondary)
            }

            Picker(L10n.reasoningEffort, selection: Binding(
                get: { efforts.contains(remote.reasoningEffort) ? remote.reasoningEffort : "" },
                set: { saveRemote(.init(reasoningEffort: $0)) }
            )) {
                if !efforts.contains(remote.reasoningEffort) { Text(L10n.reasoningEffort).tag("") }
                ForEach(efforts, id: \.self) { Text($0).tag($0) }
            }
            .disabled(efforts.isEmpty)

            if transcribesFirst {
                Picker(L10n.transcriptionModel, selection: Binding(
                    get: { remote.transcriptionModel ?? "" },
                    set: { saveRemote(.init(transcriptionModel: .some($0))) }
                )) {
                    ForEach(audioModels) { Text($0.displayName).tag($0.id) }
                }
                .disabled(audioModels.isEmpty)
            }

            Button(L10n.serverSummaryReloadModels) { model.refresh(connectionID: connectionID, reloadModels: true) }
        } header: {
            Text(L10n.remoteProcessing)
        } footer: {
            Text(L10n.serverSummaryDescription)
        }
        .disabled(!state.canEdit)
    }

    private func selectModel(_ value: String) {
        guard let selected = models.first(where: { $0.id == value }) else { return }
        saveRemote(.init(model: selected.id, reasoningEffort: effort(for: selected)))
    }

    private func setTranscribesFirst(_ enabled: Bool) {
        let nextModels = summaryModels(transcribingFirst: enabled)
        guard let selected = nextModels.first(where: { $0.id == remote.model || remote.model.hasSuffix("." + $0.id) })
            ?? nextModels.first else { return }
        let transcriptionModel: String?
        if enabled {
            guard let audioModel = audioModels.first else { return }
            transcriptionModel = audioModel.id
        } else {
            transcriptionModel = nil
        }
        saveRemote(.init(
            model: selected.id,
            reasoningEffort: effort(for: selected),
            transcriptionModel: .some(transcriptionModel)
        ))
    }

    private func effort(for selected: ServerSummaryService.Model) -> String {
        let supported = selected.supportedReasoningLevels.map(\.effort)
        if supported.contains(remote.reasoningEffort) {
            return remote.reasoningEffort
        }
        return selected.defaultReasoningLevel ?? supported.first ?? "none"
    }

    private func summaryModels(transcribingFirst: Bool) -> [ServerSummaryService.Model] {
        state.summaryModels.filter { $0.supportsSummary(method: transcribingFirst ? "transcript" : "audio") }
    }

    private func saveRemote(_ remote: ServerAccountSettings.Patch.Remote) {
        model.save(.init(summary: .init(remote: remote)), connectionID: connectionID)
    }
}
