import Foundation
import GRDB

/// ミーティング要約を表す GRDB レコード。
struct SummaryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "summaries"

    var meetingId: UUID
    var title: String
    var summary: String
    var document: String? = nil
    var googleFileId: String?
    var createdAt: Date

    func loadDocument() -> SummaryDocument {
        if let document = document?.nilIfBlank,
           let data = document.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SummaryDocument.self, from: data) {
            return decoded
        }

        return LegacyMarkdownSummaryParser.parse(markdown: summary, title: title)
    }
}
