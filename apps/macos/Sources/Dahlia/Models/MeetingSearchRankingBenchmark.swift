import Foundation

/// 正解データに対してランキング設定を採点する。判定は LLM が作るが、探索と採点はここで決定的に行う。
enum MeetingSearchRankingBenchmark {
    /// NDCG を測る順位の深さ。
    static let cutoff = 10
    /// 座標上昇法が 1 フィールドについて試す重み。
    static let weightGrid: [Double] = [0, 1, 2, 4, 6, 10]
    /// 座標上昇法の最大周回数。改善が止まれば早期に終える。
    static let maximumPasses = 3

    /// 検索を1回実行して meeting ID の順位列を返す関数。テストではスタブに差し替える。
    typealias RankedResultsProvider = @Sendable (String, MeetingSearchRankingPolicy) async throws -> [UUID]

    /// 現在の設定、各プリセット、座標上昇法で見つけた最良の重みを採点する。
    static func run(
        judgments: [MeetingSearchJudgment],
        current: MeetingSearchRankingPolicy,
        generatedAt: Date,
        rankedResults: RankedResultsProvider
    ) async throws -> MeetingSearchBenchmarkResult {
        let currentScore = try await score(current, judgments: judgments, rankedResults: rankedResults)
        var presetScores: [MeetingSearchPresetScore] = []
        var best = currentScore
        for preset in MeetingSearchRankingPreset.allCases {
            guard let policy = preset.policy else { continue }
            let presetScore = policy == current
                ? currentScore
                : try await score(policy, judgments: judgments, rankedResults: rankedResults)
            presetScores.append(MeetingSearchPresetScore(preset: preset, score: presetScore))
            if isBetter(presetScore, than: best) { best = presetScore }
        }
        let optimized = try await optimize(
            from: best,
            judgments: judgments,
            rankedResults: rankedResults
        )
        return MeetingSearchBenchmarkResult(
            current: currentScore,
            presets: presetScores,
            recommended: isBetter(optimized, than: best) ? optimized : best,
            judgmentCount: judgments.count,
            generatedAt: generatedAt
        )
    }

    /// 1 フィールドずつ粗いグリッドで最良値へ動かす座標上昇法。全組み合わせは探索しない。
    static func optimize(
        from start: MeetingSearchRankingScore,
        judgments: [MeetingSearchJudgment],
        rankedResults: RankedResultsProvider
    ) async throws -> MeetingSearchRankingScore {
        var best = start
        var evaluated: [MeetingSearchRankingPolicy: MeetingSearchRankingScore] = [start.policy: start]
        for _ in 0 ..< maximumPasses {
            let passStart = best
            for field in MeetingSearchField.allCases {
                for weight in weightGrid {
                    try Task.checkCancellation()
                    let candidate = best.policy.settingWeight(weight, for: field)
                    guard candidate != best.policy else { continue }
                    let candidateScore: MeetingSearchRankingScore
                    if let cached = evaluated[candidate] {
                        candidateScore = cached
                    } else {
                        candidateScore = try await score(
                            candidate,
                            judgments: judgments,
                            rankedResults: rankedResults
                        )
                        evaluated[candidate] = candidateScore
                    }
                    if isBetter(candidateScore, than: best) { best = candidateScore }
                }
            }
            guard best.policy != passStart.policy else { break }
        }
        return best
    }

    static func score(
        _ policy: MeetingSearchRankingPolicy,
        judgments: [MeetingSearchJudgment],
        rankedResults: RankedResultsProvider
    ) async throws -> MeetingSearchRankingScore {
        var gainTotal = 0.0
        var reciprocalRankTotal = 0.0
        var evaluated = 0
        for judgment in judgments where !judgment.entries.isEmpty {
            try Task.checkCancellation()
            let ranked = try await rankedResults(judgment.query, policy)
            let grades = Dictionary(
                judgment.entries.map { ($0.meetingID, Double($0.grade.rawValue)) },
                uniquingKeysWith: max
            )
            gainTotal += normalizedDiscountedCumulativeGain(ranked: ranked, grades: grades)
            reciprocalRankTotal += reciprocalRank(ranked: ranked, grades: grades)
            evaluated += 1
        }
        guard evaluated > 0 else {
            return MeetingSearchRankingScore(
                policy: policy,
                normalizedDiscountedCumulativeGain: 0,
                meanReciprocalRank: 0,
                evaluatedQueryCount: 0
            )
        }
        return MeetingSearchRankingScore(
            policy: policy,
            normalizedDiscountedCumulativeGain: gainTotal / Double(evaluated),
            meanReciprocalRank: reciprocalRankTotal / Double(evaluated),
            evaluatedQueryCount: evaluated
        )
    }

    static func normalizedDiscountedCumulativeGain(
        ranked: [UUID],
        grades: [UUID: Double]
    ) -> Double {
        let ideal = discountedCumulativeGain(grades.values.sorted(by: >))
        guard ideal > 0 else { return 0 }
        let actual = discountedCumulativeGain(ranked.prefix(cutoff).map { grades[$0] ?? 0 })
        return actual / ideal
    }

    static func reciprocalRank(ranked: [UUID], grades: [UUID: Double]) -> Double {
        guard let match = ranked.prefix(cutoff).enumerated().first(where: { (grades[$0.element] ?? 0) > 0 })
        else { return 0 }
        return 1 / Double(match.offset + 1)
    }

    private static func discountedCumulativeGain(_ gains: some Sequence<Double>) -> Double {
        gains.prefix(cutoff).enumerated().reduce(0) { total, entry in
            total + (pow(2, entry.element) - 1) / log2(Double(entry.offset) + 2)
        }
    }

    /// NDCG を主指標にし、同点なら MRR で比べる。
    /// 同点の候補は採用しない。正解データが触れていないフィールドの重みを、無関係な理由で動かさないため。
    private static func isBetter(
        _ candidate: MeetingSearchRankingScore,
        than current: MeetingSearchRankingScore
    ) -> Bool {
        let gainDifference = candidate.normalizedDiscountedCumulativeGain
            - current.normalizedDiscountedCumulativeGain
        if abs(gainDifference) > 0.0001 { return gainDifference > 0 }
        return candidate.meanReciprocalRank - current.meanReciprocalRank > 0.0001
    }
}
