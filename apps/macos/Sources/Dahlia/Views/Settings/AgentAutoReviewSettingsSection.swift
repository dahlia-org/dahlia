import SwiftUI

struct AgentAutoReviewSettingsSection: View {
    @AppStorage private var selectedModel: String
    @AppStorage private var triageEnabled: Bool
    @State private var isTriageUnavailable = false
    @State private var isCheckingTriage = false
    @State private var models: [CodexModel] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init() {
        _selectedModel = AppStorage(wrappedValue: "", AgentAutoReviewSettings.defaultsKey())
        _triageEnabled = AppStorage(wrappedValue: false, AgentAutoReviewSettings.triageDefaultsKey())
    }

    var body: some View {
        Section {
            LabeledContent {
                Picker(L10n.autoReviewModel, selection: $selectedModel) {
                    Text(L10n.autoReviewUseChatModel).font(.dahliaBody).tag("")
                    if !selectedModel.isEmpty, !models.contains(where: { $0.model == selectedModel }) {
                        Text(selectedModel).font(.dahliaBody).tag(selectedModel)
                    }
                    ForEach(models) { model in
                        Text(model.displayName).font(.dahliaBody).tag(model.model)
                    }
                }
                .labelsHidden()
            } label: {
                HStack {
                    Text(L10n.autoReviewModel)
                    SettingsInfoButton(help: L10n.autoReviewModelHelp)
                }
            }
            LabeledContent {
                Toggle(L10n.autoReviewTriage, isOn: triageBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(isCheckingTriage)
            } label: {
                HStack {
                    Text(L10n.autoReviewTriage)
                    SettingsInfoButton(help: L10n.autoReviewTriageHelp)
                }
            }
            if isTriageUnavailable {
                Text(L10n.autoReviewTriageUnavailable)
                    .font(.dahliaSecondary)
                    .foregroundStyle(.secondary)
            }
            if isLoading || isCheckingTriage {
                ProgressView().controlSize(.small)
            }
            if let errorMessage {
                SettingsStatusMessage(text: errorMessage, systemImage: "exclamationmark.triangle", tint: .orange)
                Button(L10n.retry) { Task { await loadModels() } }
            }
        } header: {
            Text(L10n.autoReviewSettings).font(.dahliaSectionHeader)
        } footer: {
            Text(L10n.autoReviewSettingsDescription)
        }
        .task { await loadModels() }
        .onReceive(NotificationCenter.default.publisher(for: PiRuntimeService.modelsDidChange)) { _ in
            Task { await loadModels() }
        }
    }

    private var triageBinding: Binding<Bool> {
        Binding(
            get: { triageEnabled },
            set: { enabled in
                if enabled {
                    Task { await enableTriage() }
                } else {
                    triageEnabled = false
                }
            }
        )
    }

    private func enableTriage() async {
        guard !isCheckingTriage else { return }
        isCheckingTriage = true
        isTriageUnavailable = false
        defer { isCheckingTriage = false }
        do {
            let configuration = try await PiRuntimeService.shared.autoReviewTriage(forceRefresh: true)
            guard !Task.isCancelled else { return }
            triageEnabled = configuration != nil
            isTriageUnavailable = configuration == nil
        } catch {
            isTriageUnavailable = true
        }
    }

    private func loadModels() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await PiRuntimeService.shared.models(forceRefresh: false)
            guard !Task.isCancelled else { return }
            models = loaded.filter { !$0.hidden }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
