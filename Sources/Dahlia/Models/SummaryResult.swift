import Foundation

/// Legacy LLM structured output. Kept only for fallback decoding.
struct SummaryResult: Codable {
    let title: String
    let summary: String
    let tags: [String]
    let actionItems: [SummaryActionItem]

    init(title: String, summary: String, tags: [String], actionItems: [SummaryActionItem] = []) {
        self.title = title
        self.summary = summary
        self.tags = tags
        self.actionItems = actionItems
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case summary
        case tags
        case actionItems = "action_items"
    }
}
