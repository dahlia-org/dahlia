import Foundation
import GRDB
@testable import Dahlia
@testable import DahliaRuntimeSupport

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

            #expect(result.presets.map(\.preset) == [.standard])
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

        // MARK: - ローカル正解生成

        @Test
        @MainActor
        func localJudgmentsExcludeProjectPathAndCoverEveryRankedSearchField() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            defer { try? database.close() }
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/search-benchmark-\(UUID.v7())",
                name: "Benchmark",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let project = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                parentProjectId: nil,
                name: "ProjectNeedle",
                createdAt: .now,
                projectType: .undefined
            )
            let meetingID = UUID.v7()
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try project.insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO calendar_events(
                        ical_uid, recurrence_id, created_at, updated_at, title, description, start, "end", is_all_day
                    ) VALUES (?, '', ?, ?, ?, '', ?, ?, 0)
                    """,
                    arguments: ["calendar-id", Date.now, Date.now, "CalendarNeedle", Date.now, Date.now]
                )
                try MeetingRecord(
                    id: meetingID,
                    vaultId: vault.id,
                    projectId: project.id,
                    name: "TitleNeedle",
                    description: "DescriptionNeedle",
                    createdAt: .now,
                    updatedAt: .now,
                    recordingStartedAt: .now,
                    calendarEventIcalUid: "calendar-id",
                    calendarEventRecurrenceId: ""
                ).insert(db)
                let tag = TagRecord(id: nil, name: "TagNeedle", colorHex: "#808080", createdAt: .now)
                try tag.insert(db)
                try db.execute(
                    sql: "INSERT INTO meeting_tags(meetingId, tagId) VALUES(?, ?)",
                    arguments: [meetingID, db.lastInsertedRowID]
                )
                try SummaryRecord(
                    meetingId: meetingID,
                    title: "Summary",
                    document: SummaryDocument(
                        title: "Summary",
                        description: "",
                        sections: [
                            SummarySection(id: .v7(), heading: "", blocks: [.paragraph("SummaryNeedle")]),
                        ],
                        tags: [],
                        actionItems: []
                    ).databaseJSONString(),
                    createdAt: .now
                ).insert(db)
            }

            let list = try await MeetingSearchJudgmentService.generateJudgments(
                vaultID: vault.id,
                dbQueue: database.searchDBQueue
            )
            let queries = Set(list.judgments.map(\.query))

            #expect(queries.isSuperset(of: [
                "TitleNeedle", "TagNeedle", "CalendarNeedle", "DescriptionNeedle", "SummaryNeedle",
            ]))
            #expect(!queries.contains("ProjectNeedle"))
            #expect(list.judgments.allSatisfy { $0.entries.first == .init(meetingID: meetingID, grade: .exact) })
        }

        @Test
        func legacyProjectWeightedJudgmentsAreNotReused() throws {
            let suiteName = "SearchRankingBenchmarkTests-\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let list = MeetingSearchJudgmentList(
                vaultID: .v7(),
                generatedAt: .now,
                sampledMeetingCount: 1,
                judgments: [MeetingSearchJudgment(
                    query: "ProjectNeedle",
                    entries: [.init(meetingID: .v7(), grade: .exact)]
                )]
            )
            defaults.set(try JSONEncoder().encode(list), forKey: "meetingSearchBenchmarkJudgments")

            #expect(AppSettings.meetingSearchJudgmentList(in: defaults) == nil)

            AppSettings.storeMeetingSearchJudgmentList(list, in: defaults)
            #expect(AppSettings.meetingSearchJudgmentList(in: defaults) == list)
        }

        @Test(.timeLimit(.minutes(1)))
        @MainActor
        func benchmarkDiscardsResultWhenRankingPolicyChanges() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            defer { try? database.close() }
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/search-benchmark-policy-\(UUID.v7())",
                name: "Benchmark",
                createdAt: .now,
                lastOpenedAt: .now
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try MeetingRecord(
                    id: .v7(),
                    vaultId: vault.id,
                    projectId: nil,
                    name: "PolicyNeedle",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            var policy = MeetingSearchRankingPolicy.standard
            let model = SearchRankingBenchmarkModel(database: database) { policy }

            model.regenerateAndRun(vaultID: vault.id)
            policy = .standard.settingWeight(3, for: .summary)

            #expect(await pollUntil { !model.isRunning })
            #expect(model.result == nil)
        }

        /// title の重みが 0 より大きいときだけ正解を先頭に返す検索のスタブ。
        private static let titleSensitiveResults: MeetingSearchRankingBenchmark.RankedResultsProvider = { _, policy in
            policy.weight(for: .title) > 0 ? [Self.first, Self.second] : [Self.second, Self.third]
        }
    }
#endif
