import SwiftUI

struct AgentAutoReviewSettingsSection: View {
    let account: CodexRuntimeProvider
    @AppStorage private var selectedModel: String
    @State private var models: [CodexModel] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(account: CodexRuntimeProvider) {
        self.account = account
        _selectedModel = AppStorage(wrappedValue: "", AgentAutoReviewSettings.defaultsKey(for: account))
    }

    var body: some View {
        Section {
            Picker(L10n.autoReviewModel, selection: $selectedModel) {
                Text(L10n.autoReviewUseChatModel).font(.dahliaBody).tag("")
                if !selectedModel.isEmpty, !models.contains(where: { $0.model == selectedModel }) {
                    Text(selectedModel).font(.dahliaBody).tag(selectedModel)
                }
                ForEach(models) { model in
                    Text(model.displayName).font(.dahliaBody).tag(model.model)
                }
            }
            if isLoading {
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

    private func loadModels() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await PiRuntimeService.shared.models(for: account, forceRefresh: false)
            guard !Task.isCancelled else { return }
            models = loaded.filter { !$0.hidden }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
