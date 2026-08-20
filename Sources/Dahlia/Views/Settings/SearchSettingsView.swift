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

                if let error = model.lastErrorCode {
                    SettingsStatusMessage(
                        text: String(format: L10n.searchIndexErrorFormat, error),
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                }
            } header: {
                Text(L10n.searchIndex)
            } footer: {
                Text(L10n.searchIndexDescription)
            }

            Section {
                Button(L10n.rebuildSearchIndex) {
                    Task { await model.rebuild() }
                }
                .buttonStyle(.dahlia(.primary))
                .disabled(model.isRequestingRebuild)
            } footer: {
                Text(L10n.rebuildSearchIndexDescription)
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

    private var localizedPhase: String {
        switch model.phase {
        case "pending": L10n.searchIndexPending
        case "metadata": L10n.searchIndexMetadata
        case "ready": L10n.searchIndexReady
        case "failed": L10n.searchIndexFailed
        default: model.phase
        }
    }
}
