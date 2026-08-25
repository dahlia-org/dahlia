/// AI 要約に含める情報量。
enum SummaryDetailLevel: String, CaseIterable, Identifiable {
    case concise
    case standard
    case detailed
    case eventSession

    static let defaultValue = Self.detailed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .concise: L10n.summaryDetailConcise
        case .standard: L10n.summaryDetailStandard
        case .detailed: L10n.summaryDetailDetailed
        case .eventSession: L10n.summaryDetailEventSession
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
        case .eventSession:
            """
            Summarize this as an event or conference session rather than a meeting. Follow the session's narrative and explain its key claims,
            concepts, demonstrations, examples, and takeaways with enough context to understand them. Attribute statements to speakers when
            identifiable. Add fine-grained slide or screenshot references only where they provide useful evidence, and do not invent slide
            boundaries, citations, or content.
            """
        }
    }

    var mergePriority: Int {
        switch self {
        case .concise: 0
        case .standard: 1
        case .detailed: 2
        case .eventSession: 3
        }
    }

    static func fromPersistedValue(_ value: String) -> Self {
        Self(rawValue: value) ?? defaultValue
    }
}
