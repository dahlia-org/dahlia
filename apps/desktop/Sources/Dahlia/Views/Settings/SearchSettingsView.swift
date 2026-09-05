import SwiftUI

struct SearchSettingsView: View {
    @State private var model: SearchSettingsModel
    @State private var benchmark: SearchRankingBenchmarkModel
    @State private var isAdvancedSettingsExpanded = false
    @ObservedObject private var settings = AppSettings.shared

    init(database: AppDatabaseManager?) {
        _model = State(initialValue: SearchSettingsModel(database: database))
        _benchmark = State(initialValue: SearchRankingBenchmarkModel(database: database))
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
                Button {
                    isAdvancedSettingsExpanded.toggle()
                } label: {
                    HStack {
                        Image(systemName: isAdvancedSettingsExpanded ? "chevron.down" : "chevron.right")
                            .accessibilityHidden(true)
                        Text(L10n.advancedSearchSettings)
                            .bold()
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(isAdvancedSettingsExpanded ? L10n.collapse : L10n.expand)

                if isAdvancedSettingsExpanded {
                    VStack(alignment: .leading) {
                        Text(L10n.searchRanking)
                            .font(.headline)

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

                        Text(L10n.searchRankingDescription)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading) {
                        benchmarkHeader
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
                        Text(L10n.searchBenchmarkDescription)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            isAdvancedSettingsExpanded = false
            benchmark.loadStoredJudgments(vaultID: settings.currentVault?.id)
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var benchmarkHeader: some View {
        HStack {
            Text(L10n.searchBenchmark)
                .font(.headline)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(
                        format: L10n.searchBenchmarkRecommendationFormat,
                        weightsLabel(result.recommended.policy)
                    ))
                    Text(scoreLabel(result.recommended))
                }
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
        weightValueLabel(settings.meetingSearchRankingPolicy.weight(for: field))
    }

    private func weightValueLabel(_ weight: Double) -> String {
        weight == 0 ? L10n.searchRankingFieldExcluded : L10n.searchRankingWeight(weight)
    }

    /// 推奨を適用する前に、重みそのものを示す。重み 0 のフィールドは検索対象から外れるため明示する。
    private func weightsLabel(_ policy: MeetingSearchRankingPolicy) -> String {
        MeetingSearchField.allCases
            .map { "\($0.displayName) \(weightValueLabel(policy.weight(for: $0)))" }
            .joined(separator: " / ")
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
