import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SearchRankingBenchmarkTests {
        private static let first = UUID.v7()
        private static let second = UUID.v7()
        private static let third = UUID.v7()

        // MARK: - 指標

        @Test
        func perfectOrderScoresOne() {
            let grades = [Self.first: 3.0, Self.second: 2.0]

            let gain = MeetingSearchRankingBenchmark.normalizedDiscountedCumulativeGain(
                ranked: [Self.first, Self.second, Self.third],
                grades: grades
            )

            #expect(abs(gain - 1) < 0.0001)
        }

        @Test
        func reversedOrderScoresBelowPerfectButAboveZero() {
            let grades = [Self.first: 3.0, Self.second: 2.0]

            let reversed = MeetingSearchRankingBenchmark.normalizedDiscountedCumulativeGain(
                ranked: [Self.second, Self.first],
                grades: grades
            )

            #expect(reversed < 1)
            #expect(reversed > 0)
        }

        @Test
        func resultsWithoutAnyRelevantMeetingScoreZero() {
            let grades = [Self.first: 3.0]

            let gain = MeetingSearchRankingBenchmark.normalizedDiscountedCumulativeGain(
                ranked: [Self.second, Self.third],
                grades: grades
            )
            let rank = MeetingSearchRankingBenchmark.reciprocalRank(
                ranked: [Self.second, Self.third],
                grades: grades
            )

            #expect(gain == 0)
            #expect(rank == 0)
        }

        @Test
        func reciprocalRankUsesTheFirstRelevantPosition() {
            let grades = [Self.third: 1.0]

            let rank = MeetingSearchRankingBenchmark.reciprocalRank(
                ranked: [Self.first, Self.second, Self.third],
                grades: grades
            )

            #expect(abs(rank - 1.0 / 3.0) < 0.0001)
        }

        /// 打ち切り順位より下の正解は加点しない。
        @Test
        func matchesBelowTheCutoffAreIgnored() {
            let grades = [Self.first: 3.0]
            let padding = (0 ..< MeetingSearchRankingBenchmark.cutoff).map { _ in UUID.v7() }

            let gain = MeetingSearchRankingBenchmark.normalizedDiscountedCumulativeGain(
                ranked: padding + [Self.first],
                grades: grades
            )

            #expect(gain == 0)
        }

        // MARK: - 探索

        /// title を重視した設定でだけ正解が 1 位に来る検索を模擬し、探索がその重みへ寄せることを確かめる。
        @Test
        func optimizationMovesWeightsTowardTheBetterScoringField() async throws {
            let judgments = [
                MeetingSearchJudgment(
                    query: "q",
                    entries: [.init(meetingID: Self.first, grade: .exact)]
                ),
            ]
            let start = try await MeetingSearchRankingBenchmark.score(
                MeetingSearchRankingPolicy.standard.settingWeight(0, for: .title),
                judgments: judgments,
                rankedResults: Self.titleSensitiveResults
            )

            let optimized = try await MeetingSearchRankingBenchmark.optimize(
                from: start,
                judgments: judgments,
                rankedResults: Self.titleSensitiveResults
            )

            #expect(start.normalizedDiscountedCumulativeGain == 0)
            #expect(optimized.normalizedDiscountedCumulativeGain == 1)
            #expect(optimized.policy.weight(for: .title) > 0)
        }

        @Test
        func runReportsEveryPresetAndFlagsAnImprovement() async throws {
            let judgments = [
                MeetingSearchJudgment(
                    query: "q",
                    entries: [.init(meetingID: Self.first, grade: .exact)]
                ),
            ]

            let result = try await MeetingSearchRankingBenchmark.run(
                judgments: judgments,
                current: MeetingSearchRankingPolicy.standard.settingWeight(0, for: .title),
                generatedAt: Date(timeIntervalSince1970: 0),
                rankedResults: Self.titleSensitiveResults
            )

            #expect(result.presets.map(\.preset) == [.standard, .titleAndTags, .content])
            #expect(result.judgmentCount == 1)
            #expect(result.current.normalizedDiscountedCumulativeGain == 0)
            #expect(result.recommendationImprovesCurrent)
        }

        @Test
        func scoreIgnoresJudgmentsWithoutEntries() async throws {
            let judgments = [MeetingSearchJudgment(query: "q", entries: [])]

            let score = try await MeetingSearchRankingBenchmark.score(
                .standard,
                judgments: judgments,
                rankedResults: Self.titleSensitiveResults
            )

            #expect(score.evaluatedQueryCount == 0)
            #expect(score.normalizedDiscountedCumulativeGain == 0)
        }

        // MARK: - 判定の取り込み

        @Test
        func decodingDropsUnknownMeetingsInvalidGradesAndWeakQueries() {
            let known = Self.first
            let response = """
            {"judgments": [
              {"query": "有効なクエリ", "meetings": [
                {"id": "\(known.uuidString)", "grade": 3},
                {"id": "\(UUID.v7().uuidString)", "grade": 3},
                {"id": "\(known.uuidString)", "grade": 2},
                {"id": "not-a-uuid", "grade": 2}
              ]},
              {"query": "関連だけ", "meetings": [{"id": "\(known.uuidString)", "grade": 1}]},
              {"query": "x", "meetings": [{"id": "\(known.uuidString)", "grade": 3}]},
              {"query": "範囲外", "meetings": [{"id": "\(known.uuidString)", "grade": 9}]}
            ]}
            """

            let judgments = MeetingSearchJudgmentService.decodeJudgments(
                from: response,
                knownIDs: [known]
            )

            #expect(judgments.map(\.query) == ["有効なクエリ"])
            #expect(judgments.first?.entries == [.init(meetingID: known, grade: .exact)])
        }

        @Test
        func decodingMalformedResponsesYieldsNoJudgments() {
            #expect(MeetingSearchJudgmentService.decodeJudgments(from: "not json", knownIDs: []).isEmpty)
            #expect(MeetingSearchJudgmentService.decodeJudgments(from: "{}", knownIDs: []).isEmpty)
        }

        /// title の重みが 0 より大きいときだけ正解を先頭に返す検索のスタブ。
        private static let titleSensitiveResults: MeetingSearchRankingBenchmark.RankedResultsProvider = { _, policy in
            policy.weight(for: .title) > 0 ? [Self.first, Self.second] : [Self.second, Self.third]
        }
    }
#endif
