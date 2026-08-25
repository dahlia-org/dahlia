import Foundation
import GRDB
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    @MainActor
    struct SearchRankingPolicyTests {
        // MARK: - 重みの正規化と永続化

        @Test
        func weightsAreClampedToTheSupportedRange() {
            let policy = MeetingSearchRankingPolicy(weights: [
                .title: 42,
                .tags: -5,
                .calendar: 3,
                .description: 3,
                .summary: 3,
            ])

            #expect(policy.weight(for: .title) == MeetingSearchRankingPolicy.maximumWeight)
            #expect(policy.weight(for: .tags) == MeetingSearchRankingPolicy.minimumWeight)
        }

        @Test
        func policyWithEveryWeightZeroFallsBackToTheStandardPreset() {
            let policy = MeetingSearchRankingPolicy(
                weights: Dictionary(uniqueKeysWithValues: MeetingSearchField.allCases.map { ($0, 0.0) })
            )

            #expect(policy == .standard)
        }

        @Test
        func missingFieldsInheritTheStandardWeights() {
            let policy = MeetingSearchRankingPolicy(weights: [.summary: 9])

            #expect(policy.weight(for: .summary) == 9)
            #expect(policy.weight(for: .title) == MeetingSearchRankingPolicy.standard.weight(for: .title))
        }

        @Test
        func encodingRoundTripsAndIgnoresUnknownFields() throws {
            let policy = MeetingSearchRankingPolicy(weights: [
                .title: 1,
                .tags: 2,
                .calendar: 4,
                .description: 5,
                .summary: 6,
            ])
            let encoded = try JSONEncoder().encode(policy)

            let decoded = try JSONDecoder().decode(MeetingSearchRankingPolicy.self, from: encoded)
            let withUnknownField = try JSONDecoder().decode(
                MeetingSearchRankingPolicy.self,
                from: Data(#"{"title": 7, "transcript": 9}"#.utf8)
            )

            #expect(decoded == policy)
            #expect(withUnknownField.weight(for: .title) == 7)
            #expect(withUnknownField.weight(for: .summary) == MeetingSearchRankingPolicy.standard.weight(for: .summary))
        }

        @Test
        func presetsResolveFromWeightsAndAdjustmentsBecomeCustom() {
            let adjusted = MeetingSearchRankingPolicy.standard.settingWeight(7, for: .summary)

            #expect(MeetingSearchField.allCases.map { MeetingSearchRankingPolicy.standard.weight(for: $0) } == [
                10, 6, 4, 2, 2,
            ])
            #expect(MeetingSearchRankingPreset.allCases == [.standard, .custom])
            #expect(MeetingSearchRankingPreset.matching(.standard) == .standard)
            #expect(MeetingSearchRankingPreset.matching(adjusted) == .custom)
            #expect(MeetingSearchRankingPreset.custom.policy == nil)
        }

        /// 重み 0 のフィールドはカラムフィルタから外れ、一致対象にならない。
        @Test
        func columnFilterOmitsFieldsWeightedZero() {
            let policy = MeetingSearchRankingPolicy.standard
                .settingWeight(0, for: .summary)
                .settingWeight(0, for: .calendar)

            #expect(policy.columnFilter == "{title tags description}")
            #expect(policy.matchExpression("\"a\"") == "{title tags description} : (\"a\")")
        }

        /// 一致フィールドの判定順は重みの降順で、同値は宣言順で解決する。
        @Test
        func rankedFieldsOrderByWeightThenDeclarationOrder() {
            #expect(MeetingSearchRankingPolicy.standard.rankedFields == [
                .title, .tags, .calendar, .description, .summary,
            ])
            #expect(!MeetingSearchRankingPolicy.standard.settingWeight(0, for: .tags).rankedFields.contains(.tags))
        }

        // MARK: - BM25 のカラム順

        /// `bm25RankingSQL` の重みは `search_documents_fts` のカラム位置に対応する。
        /// カラム順がずれると重みが別フィールドへ適用されるため、実際の索引で固定する。
        @Test
        func bm25WeightsMapToTheDeclaredColumnOrder() async throws {
            let fixture = try await RankingFixture()
            let onlyTitle = try #require(fixture.ids["title"])
            let onlySummary = try #require(fixture.ids["summary"])

            let favoringTitle = try await fixture.search(policy: fixture.policy(strong: .title, weak: .summary))
            let favoringSummary = try await fixture.search(policy: fixture.policy(strong: .summary, weak: .title))

            #expect(favoringTitle == [onlyTitle, onlySummary])
            #expect(favoringSummary == [onlySummary, onlyTitle])
        }

        // MARK: - 検索順位

        @Test
        func standardPresetRanksTitleAboveTagAboveSummary() async throws {
            let fixture = try await RankingFixture()

            let ranked = try await fixture.search(policy: .standard)

            #expect(ranked == [fixture.ids["title"], fixture.ids["tag"], fixture.ids["summary"]].compactMap(\.self))
        }

        @Test
        func customPolicyRanksSummaryAboveTitle() async throws {
            let fixture = try await RankingFixture()
            let customPolicy = MeetingSearchRankingPolicy.standard
                .settingWeight(1, for: .title)
                .settingWeight(10, for: .summary)

            let ranked = try await fixture.search(policy: customPolicy)

            #expect(ranked.first == fixture.ids["summary"])
        }

        /// 重み 0 のフィールドだけで一致する meeting は結果に現れない。
        @Test
        func zeroWeightFieldIsExcludedFromResults() async throws {
            let fixture = try await RankingFixture()
            let policy = MeetingSearchRankingPolicy.standard.settingWeight(0, for: .summary)

            let ranked = try await fixture.search(policy: policy)

            #expect(!ranked.contains { $0 == fixture.ids["summary"] })
            #expect(ranked.contains { $0 == fixture.ids["title"] })
        }

        /// 除外したフィールドで一致した meeting は `searchMatchContext` の判定にも現れない。
        @Test
        func matchContextReportsTheHighestWeightedMatchingField() async throws {
            let fixture = try await RankingFixture()
            let titleID = try #require(fixture.ids["title"])

            let standard = try await fixture.page(policy: .standard)
            let withoutTitle = try await fixture.page(
                policy: MeetingSearchRankingPolicy.standard.settingWeight(0, for: .title)
            )

            #expect(standard.items.first { $0.id == titleID }?.searchMatchContext?.kind == .title)
            #expect(!withoutTitle.items.contains { $0.id == titleID })
        }

        // MARK: - Fixture

        /// 検索語 `固有検索語` が、それぞれ別のフィールドだけで一致する meeting を用意する。
        @MainActor
        private struct RankingFixture {
            nonisolated static let query = "固有検索語"

            let database: AppDatabaseManager
            let vault: VaultRecord
            let ids: [String: UUID]

            init() async throws {
                database = try AppDatabaseManager(path: ":memory:")
                vault = VaultRecord(
                    id: .v7(),
                    path: "/tmp/search-ranking-\(UUID.v7())",
                    name: "Ranking",
                    createdAt: .now,
                    lastOpenedAt: .now
                )
                let titleID = UUID.v7()
                let tagID = UUID.v7()
                let summaryID = UUID.v7()
                let vaultID = vault.id
                let vaultRecord = vault
                try await database.dbQueue.write { db in
                    try vaultRecord.insert(db)
                    try Self.meeting(id: titleID, vaultID: vaultID, name: "\(Self.query) の会議").insert(db)
                    try Self.meeting(id: tagID, vaultID: vaultID, name: "タグ側の会議").insert(db)
                    try Self.meeting(id: summaryID, vaultID: vaultID, name: "要約側の会議").insert(db)
                    let tag = TagRecord(id: nil, name: Self.query, colorHex: "#808080", createdAt: .now)
                    try tag.insert(db)
                    try db.execute(
                        sql: "INSERT INTO meeting_tags(meetingId, tagId) VALUES(?, ?)",
                        arguments: [tagID, db.lastInsertedRowID]
                    )
                    try SummaryRecord(
                        meetingId: summaryID,
                        title: "Excluded title",
                        document: SummaryDocument(
                            title: "Excluded title",
                            description: "Excluded description",
                            sections: [
                                SummarySection(id: .v7(), heading: "", blocks: [.paragraph("\(Self.query)について")]),
                            ],
                            tags: [],
                            actionItems: []
                        ).databaseJSONString(),
                        createdAt: .now
                    ).insert(db)
                }
                await database.searchIndexer.drain()
                ids = ["title": titleID, "tag": tagID, "summary": summaryID]
            }

            /// `strong` と `weak` の 2 フィールドだけを有効にした比較用の重み。
            /// 他のフィールドは 0 にして、比較対象以外の meeting を結果から外す。
            func policy(
                strong: MeetingSearchField,
                weak: MeetingSearchField
            ) -> MeetingSearchRankingPolicy {
                var weights = Dictionary(uniqueKeysWithValues: MeetingSearchField.allCases.map { ($0, 0.0) })
                weights[strong] = MeetingSearchRankingPolicy.maximumWeight
                weights[weak] = 1
                return MeetingSearchRankingPolicy(weights: weights)
            }

            func page(policy: MeetingSearchRankingPolicy) async throws -> MeetingSearchPage {
                try await MeetingRepository.searchMeetingSidebarPage(
                    vaultId: vault.id,
                    query: Self.query,
                    rankingPolicy: policy,
                    limit: 20,
                    dbQueue: database.dbQueue
                )
            }

            func search(policy: MeetingSearchRankingPolicy) async throws -> [UUID] {
                try await page(policy: policy).items.map(\.id)
            }

            private nonisolated static func meeting(id: UUID, vaultID: UUID, name: String) -> MeetingRecord {
                MeetingRecord(
                    id: id,
                    vaultId: vaultID,
                    projectId: nil,
                    name: name,
                    description: "共通の説明文",
                    createdAt: .now,
                    updatedAt: .now,
                    recordingStartedAt: .now
                )
            }
        }
    }
#endif
