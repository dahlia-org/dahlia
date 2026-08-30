import Foundation

/// ミーティング全文検索が対象にするフィールド。
/// raw value は `search_documents_fts` のカラム名と一致し、FTS のカラムフィルタにそのまま使う。
enum MeetingSearchField: String, CaseIterable, Identifiable, Sendable {
    case title
    case tags
    case calendar
    case description
    case summary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .title: L10n.title
        case .tags: L10n.tags
        case .calendar: L10n.calendar
        case .description: L10n.descriptionTitle
        case .summary: L10n.summary
        }
    }
}

/// ミーティング全文検索のランキング設定。フィールドごとの重みを BM25 のカラム重みとして使う。
/// 重み 0 のフィールドは順位への寄与を失うだけでなく、カラムフィルタで一致対象からも外れる。
struct MeetingSearchRankingPolicy: Hashable, Sendable {
    static let minimumWeight: Double = 0
    static let maximumWeight: Double = 10

    /// 現行の既定。title を最優先し、tag、calendar、description/summary の順に下げる。
    static let standard = Self(weights: [
        .title: 10,
        .tags: 6,
        .calendar: 4,
        .description: 2,
        .summary: 2,
    ])

    private(set) var weights: [MeetingSearchField: Double]

    /// 重みは 0...10 に丸める。全フィールドが 0 になる設定は検索不能になるため既定へ戻す。
    init(weights: [MeetingSearchField: Double]) {
        var normalized: [MeetingSearchField: Double] = [:]
        for field in MeetingSearchField.allCases {
            let value = weights[field] ?? Self.standard.weights[field] ?? 0
            normalized[field] = min(max(value, Self.minimumWeight), Self.maximumWeight)
        }
        self.weights = normalized.values.allSatisfy { $0 == 0 } ? Self.standard.weights : normalized
    }

    func weight(for field: MeetingSearchField) -> Double {
        weights[field] ?? 0
    }

    func settingWeight(_ weight: Double, for field: MeetingSearchField) -> Self {
        var updated = weights
        updated[field] = weight
        return Self(weights: updated)
    }

    /// 重みが 0 より大きいフィールドを、重みの降順、同値なら宣言順で返す。
    /// 一致したフィールドの表示（`searchMatchContext`）もこの順序で決める。
    var rankedFields: [MeetingSearchField] {
        MeetingSearchField.allCases
            .filter { weight(for: $0) > 0 }
            .enumerated()
            .sorted {
                let lhs = weight(for: $0.element)
                let rhs = weight(for: $1.element)
                return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
            }
            .map(\.element)
    }

    /// 一致対象を有効なフィールドだけに限定する FTS5 のカラムフィルタ。
    var columnFilter: String {
        let columns = MeetingSearchField.allCases
            .filter { weight(for: $0) > 0 }
            .map(\.rawValue)
            .joined(separator: " ")
        return "{\(columns)}"
    }

    /// `search_documents_fts` のカラム順に対応する BM25 ランキング式。
    /// カラム順は `ScreenshotOCRSearchMigration` が定義し、`SearchRankingPolicyTests` がピン留めしている。
    var bm25RankingSQL: String {
        let columnWeights: [Double] = [
            weight(for: .title),
            weight(for: .description),
            weight(for: .summary),
            weight(for: .calendar),
            weight(for: .tags),
            0, // projectPath は Project 検索と明示的な絞り込みだけで使う
            0, // ocr は screenshot 専用で meeting 文書では常に空
            0, // caption も同様
        ]
        let formatted = columnWeights.map { String(format: "%.4f", $0) }.joined(separator: ", ")
        return "bm25(search_documents_fts, \(formatted))"
    }

    /// 有効なフィールドに限定した MATCH 式を組み立てる。
    func matchExpression(_ expression: String) -> String {
        "\(columnFilter) : (\(expression))"
    }
}

extension MeetingSearchRankingPolicy: Codable {
    init(from decoder: any Decoder) throws {
        let stored = try decoder.singleValueContainer().decode([String: Double].self)
        var weights: [MeetingSearchField: Double] = [:]
        for (key, value) in stored {
            guard let field = MeetingSearchField(rawValue: key) else { continue }
            weights[field] = value
        }
        self.init(weights: weights)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: weights.map { ($0.key.rawValue, $0.value) }))
    }
}

/// 設定画面が提示するランキングのプリセット。
enum MeetingSearchRankingPreset: String, CaseIterable, Identifiable, Sendable {
    case standard
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: L10n.searchRankingPresetStandard
        case .custom: L10n.searchRankingPresetCustom
        }
    }

    /// `custom` はユーザーが調整した重みをそのまま使うため、固定の重みを持たない。
    var policy: MeetingSearchRankingPolicy? {
        switch self {
        case .standard:
            .standard
        case .custom:
            nil
        }
    }

    /// 標準の重みと一致しなければ `custom`。
    static func matching(_ policy: MeetingSearchRankingPolicy) -> Self {
        policy == .standard ? .standard : .custom
    }
}
