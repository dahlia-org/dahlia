import Foundation

/// サマリーの title / description から Meeting のメタデータへ反映する値を作る規則。
/// アプリの生成経路と MCP の更新経路で同じ結果になる必要があるため、ここに 1 つだけ置く。
public enum SummaryGeneratedMetadata {
    public static let titleMaximumLength = 120
    public static let descriptionMaximumLength = 240

    /// 改行を空白へ畳み、空白のみなら nil、そうでなければ先頭 `maximumLength` 文字を返す。
    public static func normalized(_ value: String, maximumLength: Int) -> String? {
        let oneLine = value
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .summaryNilIfBlank
        return oneLine.map { String($0.prefix(maximumLength)) }
    }

    public static func normalizedTitle(_ value: String) -> String? {
        normalized(value, maximumLength: titleMaximumLength)
    }

    public static func normalizedDescription(_ value: String) -> String? {
        normalized(value, maximumLength: descriptionMaximumLength)
    }
}
