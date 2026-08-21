import SwiftUI

struct SearchSettingsView: View {
    @State private var model: SearchSettingsModel

    init(database: AppDatabaseManager?) {
        _model = State(initialValue: SearchSettingsModel(database: database))
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.searchIndexStatus, value: localizedPhase)
                LabeledContent(L10n.searchQueuePending, value: model.pendingJobCount.formatted())
                LabeledContent(L10n.searchQueueProcessing, value: model.processingJobCount.formatted())

                if model.phase != "ready", model.totalCount > 0 {
                    ProgressView(value: model.progress) {
                        Text(L10n.searchIndexProgress)
                    } currentValueLabel: {
                        Text("\(model.completedCount.formatted()) / \(model.totalCount.formatted())")
                    }
                }

                HStack {
                    Spacer()
                    Button(L10n.rebuildFullTextSearch) {
                        Task { await model.rebuildFullTextIndex() }
                    }
                    .buttonStyle(.dahlia())
                    .disabled(model.isRequestingRebuild)
                }

                if let error = model.lastErrorCode {
                    SettingsStatusMessage(
                        text: String(format: L10n.searchIndexErrorFormat, error),
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                }
            } header: {
                Text(L10n.fullTextSearch)
            } footer: {
                Text(L10n.searchIndexDescription)
            }

            Section {
                Toggle(L10n.enableVectorSearch, isOn: vectorSearchEnabledBinding)
                    .toggleStyle(.switch)
                    .disabled(model.isUpdatingVectorSearchEnabled || model.isDownloadingModel)

                if model.isVectorSearchEnabled {
                    LabeledContent(
                        L10n.embeddingModel,
                        value: model.isModelInstalled ? L10n.installed : L10n.notInstalled
                    )
                    LabeledContent(L10n.vectorIndexStatus, value: localizedVectorPhase)
                    if model.vectorPhase == "metadata", model.vectorTotalCount > 0 {
                        ProgressView(value: model.vectorProgress) {
                            Text(L10n.searchIndexProgress)
                        } currentValueLabel: {
                            Text("\(model.vectorCompletedCount.formatted()) / \(model.vectorTotalCount.formatted())")
                        }
                    }
                    if model.isDownloadingModel {
                        ProgressView(value: model.modelDownloadProgress) {
                            Text(L10n.downloadingEmbeddingModel)
                        }
                    } else if !model.isModelInstalled {
                        Button(L10n.acceptTermsAndDownloadModel) {
                            Task { await model.downloadModel() }
                        }
                        .buttonStyle(.dahlia(.primary))
                    }
                    HStack {
                        Link(destination: URL(string: "https://ai.google.dev/gemma/terms")!) {
                            Label(L10n.gemmaTerms, systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.dahlia())
                        Spacer()
                        if model.isModelInstalled {
                            Button(L10n.rebuildVectorSearch) {
                                Task { await model.rebuildVectorIndex() }
                            }
                            .buttonStyle(.dahlia())
                            .disabled(model.isRequestingRebuild)
                        }
                    }
                    if let error = model.vectorLastErrorCode {
                        SettingsStatusMessage(
                            text: String(format: L10n.searchIndexErrorFormat, error),
                            systemImage: "exclamationmark.triangle",
                            tint: .orange
                        )
                    }
                }
            } header: {
                Text(L10n.vectorSearch)
            } footer: {
                Text(L10n.embeddingModelDescription)
            }

        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var vectorSearchEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.isVectorSearchEnabled },
            set: { isEnabled in Task { await model.setVectorSearchEnabled(isEnabled) } }
        )
    }

    private var localizedPhase: String {
        switch model.phase {
        case "pending": L10n.searchIndexPending
        case "metadata": L10n.searchIndexMetadata
        case "ready": L10n.searchIndexReady
        case "failed": L10n.searchIndexFailed
        default: model.phase
        }
    }

    private var localizedVectorPhase: String {
        switch model.vectorPhase {
        case "pending": L10n.searchIndexPending
        case "metadata": L10n.searchIndexMetadata
        case "ready": L10n.searchIndexReady
        case "failed": L10n.searchIndexFailed
        default: model.vectorPhase
        }
    }
}
