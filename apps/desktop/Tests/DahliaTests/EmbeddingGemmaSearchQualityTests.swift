import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct EmbeddingGemmaSearchQualityTests {
        @Test(.timeLimit(.minutes(10)))
        func calibratedThresholdImprovesPinnedModelJudgments() async throws {
            guard let basePath = ProcessInfo.processInfo.environment["DAHLIA_EMBEDDING_TEST_BASE"] else { return }
            let service = EmbeddingGemmaService(
                baseDirectory: URL(fileURLWithPath: basePath),
                validatesRuntimeResources: false
            )
            let fixture = Self.fixture
            let documents = fixture.compactMap(\.document)
            let documentEmbeddings = try await service.documentEmbeddings(documents.map {
                DocumentEmbeddingInput(title: $0.title, text: $0.text)
            })
            var documentIndex = 0
            var queryScores: [QueryScores] = []
            for judgment in fixture {
                let queryEmbedding = try await service.queryEmbedding(judgment.query)
                let scores = try documentEmbeddings.map {
                    try EmbeddingVector.cosineSimilarity(queryEmbedding, $0)
                }
                queryScores.append(QueryScores(
                    category: judgment.category,
                    positiveIndex: judgment.document == nil ? nil : documentIndex,
                    scores: scores
                ))
                if judgment.document != nil { documentIndex += 1 }
            }

            let sweep: [Float] = [-.infinity, 0.30, 0.35, 0.40, 0.45]
            for threshold in sweep {
                let metrics = Self.quality(at: threshold, queries: queryScores)
                let classification = Self.classification(at: threshold, queries: queryScores)
                let averageCandidates = Double(queryScores.reduce(0) { total, query in
                    total + query.scores.count(where: { $0 >= threshold })
                }) / Double(queryScores.count)
                print(
                    "EmbeddingGemma threshold sweep threshold=\(threshold) "
                        + "ndcg=\(metrics.ndcgAt10) semantic_recall=\(metrics.semanticRecallAt10) "
                        + "false_positives=\(metrics.noMatchHitsAt10) macro_f1=\(classification.macroF1) "
                        + "precision=\(classification.precision) avg_candidates=\(averageCandidates)"
                )
            }

            let calibrated = Self.selectThreshold(from: queryScores)
            let baseline = Self.quality(at: -.infinity, queries: queryScores)
            let quality = Self.quality(at: calibrated, queries: queryScores)
            print(
                "EmbeddingGemma search threshold=\(calibrated) "
                    + "baseline_ndcg=\(baseline.ndcgAt10) ndcg=\(quality.ndcgAt10) "
                    + "baseline_false_positives=\(baseline.noMatchHitsAt10) "
                    + "false_positives=\(quality.noMatchHitsAt10) semantic_recall=\(quality.semanticRecallAt10)"
            )
            #expect(calibrated == HybridSearchRRF.minimumVectorSimilarity)
            #expect(quality.noMatchHitsAt10 < baseline.noMatchHitsAt10)
            #expect(quality.ndcgAt10 >= baseline.ndcgAt10)
            #expect(quality.semanticRecallAt10 >= 0.90)
        }

        private nonisolated static func selectThreshold(from queries: [QueryScores]) -> Float {
            let baseline = quality(at: -.infinity, queries: queries)
            let candidates = Set(queries.flatMap(\.scores).map { floor($0 * 100) / 100 }).filter {
                let candidate = quality(at: $0, queries: queries)
                return candidate.noMatchHitsAt10 < baseline.noMatchHitsAt10
                    && candidate.ndcgAt10 >= baseline.ndcgAt10
                    && candidate.semanticRecallAt10 >= 0.90
            }
            return candidates.max { lhs, rhs in
                let lhsScore = classification(at: lhs, queries: queries)
                let rhsScore = classification(at: rhs, queries: queries)
                if lhsScore.macroF1 != rhsScore.macroF1 { return lhsScore.macroF1 < rhsScore.macroF1 }
                if lhsScore.precision != rhsScore.precision { return lhsScore.precision < rhsScore.precision }
                return lhs > rhs
            } ?? .nan
        }

        private nonisolated static func classification(
            at threshold: Float,
            queries: [QueryScores]
        ) -> (macroF1: Double, precision: Double) {
            var f1Total = 0.0
            var truePositives = 0
            var selectedTotal = 0
            for query in queries {
                let selected = query.scores.indices.filter { query.scores[$0] >= threshold }
                selectedTotal += selected.count
                guard let positive = query.positiveIndex else {
                    f1Total += selected.isEmpty ? 1 : 0
                    continue
                }
                let found = selected.contains(positive)
                if found { truePositives += 1 }
                let precision = found ? 1 / Double(selected.count) : 0
                let recall = found ? 1.0 : 0
                f1Total += precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
            }
            return (
                f1Total / Double(queries.count),
                selectedTotal == 0 ? 1 : Double(truePositives) / Double(selectedTotal)
            )
        }

        private nonisolated static func quality(
            at threshold: Float,
            queries: [QueryScores]
        ) -> Quality {
            let ids = queries.compactMap(\.positiveIndex).map(documentID)
            var ndcg = 0.0
            var judgedQueries = 0
            var recalledSemantic = 0
            var semanticQueries = 0
            var noMatchHits = 0
            for query in queries {
                let vector = query.scores.enumerated()
                    .filter { $0.element >= threshold }
                    .sorted { lhs, rhs in
                        if lhs.element != rhs.element { return lhs.element > rhs.element }
                        return lhs.offset < rhs.offset
                    }
                    .prefix(HybridSearchRRF.candidateLimit)
                    .map { ids[$0.offset] }
                let fullText = query.category == .exact
                    ? query.positiveIndex.map { [ids[$0]] } ?? []
                    : []
                let hybrid = HybridSearchRRF.rank(fullText: fullText, vector: vector)
                if query.category == .noMatch {
                    noMatchHits += min(10, hybrid.count)
                    continue
                }
                guard let positive = query.positiveIndex else { continue }
                judgedQueries += 1
                if let rank = hybrid.prefix(10).firstIndex(of: ids[positive]) {
                    ndcg += 1 / log2(Double(rank) + 2)
                    if query.category == .semantic { recalledSemantic += 1 }
                }
                if query.category == .semantic { semanticQueries += 1 }
            }
            return Quality(
                ndcgAt10: ndcg / Double(judgedQueries),
                semanticRecallAt10: Double(recalledSemantic) / Double(semanticQueries),
                noMatchHitsAt10: noMatchHits
            )
        }

        private nonisolated static func documentID(_ index: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
        }

        private nonisolated static let fixture: [Judgment] = [
            .semantic("来期の予算を減らす話", "次年度コスト見直し", "来期はクラウド利用料と外注費を精査し、部門予算を一割削減する方針を確認した。"),
            .semantic("商談の次にやること", "商談後の次のアクション", "提案資料の更新、技術質問への回答、次回デモの日程調整を担当者ごとに決定した。"),
            .semantic("顧客が困っている点", "導入上の課題", "権限設計が複雑で運用担当者の負担が大きく、データ更新の遅延も問題になっている。"),
            .semantic("本番移行の危険性", "リリースリスク", "移行手順の検証不足とロールバック時間が主要な懸念であり、事前リハーサルが必要になった。"),
            .semantic("営業チームとの役割分担", "営業と技術の連携", "営業は契約条件と窓口対応を担当し、技術チームは構成提案と検証環境を受け持つ。"),
            .semantic("データ品質を良くする", "データ品質を改善する計画", "重複レコードの統合、必須項目の検証、欠損値の監視を順番に実施する計画を合意した。"),
            .semantic("会議で決まったこと", "意思決定事項", "試験導入を九月に開始し、対象部署を二つに限定して効果測定を行うことを正式に決定した。"),
            .semantic("採用候補者の評価", "面接フィードバック", "候補者は設計力と説明力が高い一方、大規模運用の経験について追加確認が必要と評価された。"),
            .semantic("障害の原因と再発防止", "インシデントレビュー", "接続プールの枯渇が停止原因だった。上限監視と段階的な負荷試験を再発防止策として追加する。"),
            .semantic("解約を防ぐ施策", "顧客離反を防ぐ契約継続施策", "利用率が低い部門へ個別トレーニングを提供し、月次レビューで成果を共有して契約更新につなげる。"),
            .semantic("価格交渉の着地点", "契約条件の調整", "年間契約を条件に割引率を拡大し、追加サポート費用は別枠にすることで双方が合意した。"),
            .semantic("経営陣向け報告", "エグゼクティブサマリー", "売上見込み、主要リスク、意思決定が必要な論点を一枚にまとめて役員会へ提出する。"),
            .exact("PCA井筒", "PCA井筒様 定例", "PCA井筒様との定例でデータ連携方式と検証スケジュールを確認した。"),
            .exact("AI Gateway", "DeNA AI Gateway", "社内AI Gatewayの認証、監査ログ、モデル切り替え方式について提案内容を整理した。"),
            .exact("Lakebase", "Lakebase 検証", "Lakebaseを利用したアプリケーション構成とトランザクション要件を検証した。"),
            .exact("Zerobus", "Zerobus ingest", "Zerobusによるリアルタイム取り込みのスループットと再送設計を確認した。"),
            .exact("Unity Catalog", "Unity Catalog 権限設計", "Unity Catalogのカタログ分離、権限継承、監査要件について議論した。"),
            .exact("Scikick", "Scikick デモ", "Scikick向けのデモ手順と利用データ、当日の担当者を確認した。"),
            .exact("Omnigent", "Omnigent runtime", "Omnigentのローカルruntime設定とホスト起動失敗の調査結果を共有した。"),
            .exact("DNB", "DNB 週次報告", "DNB向け週次報告の進捗、リスク、翌週の優先事項を整理した。"),
            .filtered("子プロジェクトの進捗", "配下プロジェクト進捗", "親プロジェクト配下の検証タスクは八割完了し、残りは性能試験と利用部門の確認になった。"),
            .filtered("重要タグの次アクション", "重要案件フォロー", "重要タグの付いた案件について、担当者への確認と次回提案日の確定を次の行動に設定した。"),
            .filtered("今月の契約更新", "契約更新対象", "今月末に更新期限を迎える契約の利用状況と見積条件を確認し、継続提案を準備する。"),
            .filtered("特定顧客の技術課題", "顧客別技術課題", "対象顧客ではネットワーク制限と認証連携が導入の障害であり、専用の検証を進める。"),
            .filtered("先週の未解決事項", "前週からの持ち越し", "先週決まらなかったデータ保持期間と運用担当者について、関係者から回答を集める。"),
            .noMatch("深海魚の飼育方法"),
            .noMatch("火星の気候"),
            .noMatch("フランス料理のレシピ"),
            .noMatch("古代ローマの道路"),
            .noMatch("量子重力理論"),
        ]
    }

    private struct QueryScores: Sendable {
        let category: Judgment.Category
        let positiveIndex: Int?
        let scores: [Float]
    }

    private struct Quality {
        let ndcgAt10: Double
        let semanticRecallAt10: Double
        let noMatchHitsAt10: Int
    }

    private struct SearchDocument {
        let title: String
        let text: String
    }

    private struct Judgment {
        enum Category: Sendable {
            case semantic
            case exact
            case filtered
            case noMatch
        }

        let query: String
        let category: Category
        let document: SearchDocument?

        static func semantic(_ query: String, _ title: String, _ text: String) -> Self {
            Self(query: query, category: .semantic, document: .init(title: title, text: text))
        }

        static func exact(_ query: String, _ title: String, _ text: String) -> Self {
            Self(query: query, category: .exact, document: .init(title: title, text: text))
        }

        static func filtered(_ query: String, _ title: String, _ text: String) -> Self {
            Self(query: query, category: .filtered, document: .init(title: title, text: text))
        }

        static func noMatch(_ query: String) -> Self {
            Self(query: query, category: .noMatch, document: nil)
        }
    }
#endif
