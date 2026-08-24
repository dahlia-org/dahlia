import SwiftUI

struct SearchSettingsView: View {
    @State private var model: SearchSettingsModel
    @State private var benchmark: SearchRankingBenchmarkModel
    @ObservedObject private var settings = AppSettings.shared

    init(database: AppDatabaseManager?) {
        _model = State(initialValue: SearchSettingsModel(database: database))
        _benchmark = State(initialValue: SearchRankingBenchmarkModel(database: database))
    }

    var body: some View {
        Form {
            Section {
                Picker(L10n.searchRankingPreset, selection: rankingPresetBinding) {
                    ForEach(MeetingSearchRankingPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }

                ForEach(MeetingSearchField.allCases) { field in
                    LabeledContent(field.displayName) {
                        HStack {
                            Slider(value: weightBinding(for: field), in: Self.weightRange, step: 1)
                            Text(weightLabel(for: field))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(L10n.searchRanking)
            } footer: {
                Text(L10n.searchRankingDescription)
            }

            Section {
                benchmarkControls
                if let result = benchmark.result {
                    benchmarkScores(result)
                }
                if let error = benchmark.errorMessage {
                    SettingsStatusMessage(
                        text: error,
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                }
            } header: {
                Text(L10n.searchBenchmark)
            } footer: {
                Text(L10n.searchBenchmarkDescription)
            }

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
        .onAppear { benchmark.loadStoredJudgments(vaultID: settings.currentVault?.id) }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private var benchmarkControls: some View {
        HStack {
            if benchmark.isRunning {
                ProgressView()
                    .controlSize(.small)
                Text(benchmarkPhaseLabel)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if benchmark.isRunning {
                Button(L10n.cancel) { benchmark.cancel() }
                    .buttonStyle(.dahlia())
            } else {
                if benchmark.judgmentList != nil {
                    Button(L10n.searchBenchmarkReevaluate) {
                        benchmark.runWithStoredJudgments(vaultID: settings.currentVault?.id)
                    }
                    .buttonStyle(.dahlia())
                    .disabled(!isSearchIndexReady)
                }
                Button(L10n.searchBenchmarkRun) {
                    benchmark.regenerateAndRun(vaultID: settings.currentVault?.id)
                }
                .buttonStyle(.dahlia(.primary))
                .disabled(!isSearchIndexReady)
            }
        }
    }

    @ViewBuilder
    private func benchmarkScores(_ result: MeetingSearchBenchmarkResult) -> some View {
        LabeledContent(
            L10n.searchBenchmarkQueryCount,
            value: result.judgmentCount.formatted()
        )
        LabeledContent(L10n.searchBenchmarkCurrentScore, value: scoreLabel(result.current))
        ForEach(result.presets) { entry in
            LabeledContent(entry.preset.displayName, value: scoreLabel(entry.score))
        }
        if result.recommendationImprovesCurrent {
            HStack {
                Text(String(format: L10n.searchBenchmarkRecommendationFormat, scoreLabel(result.recommended)))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.searchBenchmarkApplyRecommendation) {
                    benchmark.applyRecommendation(settings)
                }
                .buttonStyle(.dahlia(.primary))
            }
        } else {
            SettingsStatusMessage(
                text: L10n.searchBenchmarkCurrentIsBest,
                systemImage: "checkmark.circle",
                tint: .secondary
            )
        }
    }

    /// 索引が未完成のあいだは採点しても順位が安定しないため、実行させない。
    private var isSearchIndexReady: Bool {
        model.phase == "ready"
    }

    private var benchmarkPhaseLabel: String {
        switch benchmark.phase {
        case .generatingJudgments: L10n.searchBenchmarkGenerating
        case .evaluating: L10n.searchBenchmarkEvaluating
        case .idle: ""
        }
    }

    private func scoreLabel(_ score: MeetingSearchRankingScore) -> String {
        String(
            format: L10n.searchBenchmarkScoreFormat,
            score.normalizedDiscountedCumulativeGain,
            score.meanReciprocalRank
        )
    }

    private static let weightRange =
        MeetingSearchRankingPolicy.minimumWeight ... MeetingSearchRankingPolicy.maximumWeight

    /// プリセットを選ぶと重みを置き換える。`custom` は現在の重みをそのまま保つ。
    private var rankingPresetBinding: Binding<MeetingSearchRankingPreset> {
        let policy = $settings.meetingSearchRankingPolicy
        return Binding(
            get: { MeetingSearchRankingPreset.matching(policy.wrappedValue) },
            set: { preset in
                guard let presetPolicy = preset.policy else { return }
                policy.wrappedValue = presetPolicy
            }
        )
    }

    private func weightBinding(for field: MeetingSearchField) -> Binding<Double> {
        let policy = $settings.meetingSearchRankingPolicy
        return Binding(
            get: { policy.wrappedValue.weight(for: field) },
            set: { policy.wrappedValue = policy.wrappedValue.settingWeight($0, for: field) }
        )
    }

    private func weightLabel(for field: MeetingSearchField) -> String {
        let weight = settings.meetingSearchRankingPolicy.weight(for: field)
        return weight == 0 ? L10n.searchRankingFieldExcluded : L10n.searchRankingWeight(weight)
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
