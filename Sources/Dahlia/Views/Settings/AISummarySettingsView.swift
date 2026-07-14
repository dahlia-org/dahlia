import SwiftUI

/// Codex model selection for AI summaries.
struct AISummarySettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var catalog = CodexModelCatalog()
    @State private var retryTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                if catalog.isLoading {
                    LabeledContent(L10n.model) {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else if !catalog.models.isEmpty {
                    Picker(selection: modelSelection) {
                        ForEach(catalog.models) { model in
                            Text(model.displayName).tag(model.model)
                        }
                    } label: {
                        Text(L10n.model)
                        Text(L10n.codexModelDescription)
                    }
                    .pickerStyle(.menu)

                    Picker(selection: $settings.codexReasoningEffort) {
                        ForEach(catalog.effortOptions(modelID: settings.codexModelID)) { effort in
                            Text(effort.displayName).tag(effort.reasoningEffort)
                        }
                    } label: {
                        Text(L10n.reasoningEffort)
                        Text(L10n.reasoningEffortDescription)
                    }
                    .pickerStyle(.menu)
                }

                if let errorMessage = catalog.errorMessage {
                    SettingsStatusMessage(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                }

                if catalog.canRetry {
                    Button(L10n.retry, action: reload)
                        .disabled(catalog.isLoading)
                }
            } header: {
                Text(L10n.aiSummary)
            } footer: {
                Text(L10n.codexSummaryModelFooter)
            }
        }
        .formStyle(.grouped)
        .task {
            await loadModels(forceRefresh: false)
        }
        .onChange(of: settings.codexModelID) {
            resolveEffortSelection()
        }
        .onDisappear {
            retryTask?.cancel()
        }
    }

    private func reload() {
        retryTask?.cancel()
        retryTask = Task { await loadModels(forceRefresh: true) }
    }

    private func loadModels(forceRefresh: Bool) async {
        await catalog.load(forceRefresh: forceRefresh)
        guard !catalog.models.isEmpty else { return }
        if let selection = catalog.selectionToPersist(current: settings.codexModelID) {
            settings.codexModelID = selection
        }
        resolveEffortSelection()
    }

    private func resolveEffortSelection() {
        guard let effort = catalog.resolvedEffort(
            current: settings.codexReasoningEffort,
            modelID: settings.codexModelID
        ) else { return }
        settings.codexReasoningEffort = effort
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: {
                catalog.resolvedSelection(current: settings.codexModelID)
                    ?? settings.codexModelID
            },
            set: { settings.codexModelID = $0 }
        )
    }
}
