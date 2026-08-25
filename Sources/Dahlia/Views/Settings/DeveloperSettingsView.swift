import SwiftUI

/// 設定画面「開発者設定」タブ。外部サービス連携の開発者向け override と、
/// まだ一般公開していない検索ランキングの調整をまとめる。
struct DeveloperSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var benchmark: SearchRankingBenchmarkModel
    @State private var clientSecretOverride = ""

    init(database: AppDatabaseManager?) {
        _benchmark = State(initialValue: SearchRankingBenchmarkModel(database: database))
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text(L10n.googleOAuthClientIDOverride)
                    Text(L10n.googleOAuthClientIDOverrideDescription)
                        .font(.body)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)

                    TextField(
                        "",
                        text: $settings.googleOAuthClientIDOverride,
                        prompt: Text("1234567890-abcdef.apps.googleusercontent.com")
                    )
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(Text(L10n.googleOAuthClientIDOverride))
                    .onSubmit {
                        saveClientIDOverride()
                    }
                }

                VStack(alignment: .leading) {
                    Text(L10n.googleOAuthClientSecretOverride)
                    Text(L10n.googleOAuthClientSecretOverrideDescription)
                        .font(.body)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)

                    SecureField("", text: $clientSecretOverride)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text(L10n.googleOAuthClientSecretOverride))
                        .onSubmit {
                            saveClientSecretOverride()
                        }
                }

                SettingsStatusMessage(
                    text: L10n.googleOAuthOverrideReconnectNotice,
                    systemImage: "info.circle",
                    tint: .blue
                )

                Button(L10n.restoreAppDefaults) {
                    resetOverrides()
                }
                .disabled(!hasOverrides)
            } header: {
                Text(L10n.developerSettings)
            } footer: {
                Text(L10n.developerSettingsDescription)
            }

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
                                .foregroundStyle(DahliaDesign.secondaryTextColor)
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
        }
        .formStyle(.grouped)
        .task {
            clientSecretOverride = settings.googleOAuthClientSecretOverride
            benchmark.loadStoredJudgments(vaultID: settings.currentVault?.id)
        }
        .onDisappear {
            saveOverrides()
        }
    }

    @ViewBuilder
    private var benchmarkControls: some View {
        HStack {
            if benchmark.isRunning {
                ProgressView()
                    .controlSize(.small)
                Text(benchmarkPhaseLabel)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
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
                }
                Button(L10n.searchBenchmarkRun) {
                    benchmark.regenerateAndRun(vaultID: settings.currentVault?.id)
                }
                .buttonStyle(.dahlia(.primary))
            }
        }
    }

    @ViewBuilder
    private func benchmarkScores(_ result: MeetingSearchBenchmarkResult) -> some View {
        LabeledContent(L10n.searchBenchmarkQueryCount, value: result.judgmentCount.formatted())
        LabeledContent(L10n.searchBenchmarkCurrentScore, value: scoreLabel(result.current))
        ForEach(result.presets) { entry in
            LabeledContent(entry.preset.displayName, value: scoreLabel(entry.score))
        }
        if result.recommendationImprovesCurrent {
            HStack {
                Text(String(format: L10n.searchBenchmarkRecommendationFormat, scoreLabel(result.recommended)))
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
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

    private var hasOverrides: Bool {
        !settings.googleOAuthClientIDOverride.isEmpty || !clientSecretOverride.isEmpty
    }

    private func saveOverrides() {
        saveClientIDOverride()
        saveClientSecretOverride()
    }

    private func saveClientIDOverride() {
        settings.googleOAuthClientIDOverride = settings.googleOAuthClientIDOverride.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveClientSecretOverride() {
        settings.googleOAuthClientSecretOverride = clientSecretOverride
        clientSecretOverride = settings.googleOAuthClientSecretOverride
    }

    private func resetOverrides() {
        settings.googleOAuthClientIDOverride = ""
        clientSecretOverride = ""
        settings.googleOAuthClientSecretOverride = ""
    }
}
