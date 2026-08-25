import Foundation

/// ベンチマークの正解データ。1 件の検索クエリと、そのクエリで上位に来るべき meeting の組。
struct MeetingSearchJudgment: Codable, Equatable, Sendable {
    /// 関連度。NDCG の gain に使う。
    enum Grade: Int, Codable, Sendable {
        case related = 1
        case relevant = 2
        case exact = 3
    }

    struct Entry: Codable, Equatable, Sendable {
        let meetingID: UUID
        let grade: Grade
    }

    let query: String
    let entries: [Entry]
}

/// ユーザーの実データから生成した正解データ一式。
struct MeetingSearchJudgmentList: Codable, Equatable, Sendable {
    let vaultID: UUID
    let generatedAt: Date
    /// 生成時に対象とした meeting 件数。結果の信頼度を UI に示すために保持する。
    let sampledMeetingCount: Int
    let judgments: [MeetingSearchJudgment]

    var isEmpty: Bool { judgments.isEmpty }
}

/// 1 つのランキング設定を正解データで採点した結果。
struct MeetingSearchRankingScore: Equatable, Sendable {
    let policy: MeetingSearchRankingPolicy
    /// 上位 10 件の NDCG の平均。0...1。
    let normalizedDiscountedCumulativeGain: Double
    /// 最上位の正解の逆順位の平均。0...1。
    let meanReciprocalRank: Double
    /// 採点できたクエリ数。
    let evaluatedQueryCount: Int
}

/// プリセット 1 件分の採点結果。
struct MeetingSearchPresetScore: Equatable, Identifiable, Sendable {
    let preset: MeetingSearchRankingPreset
    let score: MeetingSearchRankingScore

    var id: String { preset.rawValue }
}

/// ベンチマーク 1 回分の結果。
struct MeetingSearchBenchmarkResult: Equatable, Sendable {
    /// 実行時点の設定の得点。
    let current: MeetingSearchRankingScore
    /// 各プリセットの得点。
    let presets: [MeetingSearchPresetScore]
    /// 探索で見つかった最良の重み。
    let recommended: MeetingSearchRankingScore
    let judgmentCount: Int
    let generatedAt: Date

    /// 推奨が現在の設定より明確に良いときだけ適用を促す。
    var recommendationImprovesCurrent: Bool {
        recommended.normalizedDiscountedCumulativeGain
            > current.normalizedDiscountedCumulativeGain + 0.001
    }
}
