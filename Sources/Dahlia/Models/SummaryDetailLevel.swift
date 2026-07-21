/// AI 要約に含める情報量。
enum SummaryDetailLevel: String, CaseIterable, Identifiable {
    case concise
    case standard
    case detailed

    static let defaultValue = SummaryDetailLevel.detailed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .concise: L10n.summaryDetailConcise
        case .standard: L10n.summaryDetailStandard
        case .detailed: L10n.summaryDetailDetailed
        }
    }

    var instruction: String {
        switch self {
        case .concise:
            "Keep the summary concise. Focus on important decisions, issues, and next actions, and omit minor details."
        case .standard:
            "Provide a balanced summary that covers the main topics with enough context to understand them."
        case .detailed:
            "Provide a comprehensive summary. Cover every substantive topic, relevant background and rationale, decisions, concerns, unresolved questions, and next steps. Avoid repetition and filler."
        }
    }

    static func fromPersistedValue(_ value: String) -> SummaryDetailLevel {
        SummaryDetailLevel(rawValue: value) ?? defaultValue
    }
}
