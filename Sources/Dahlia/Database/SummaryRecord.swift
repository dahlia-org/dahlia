import Foundation
import GRDB

/// ミーティング要約を表す GRDB レコード。
struct SummaryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "summaries"

    var meetingId: UUID
    var title: String
    var document: String
    var createdAt: Date

    func loadDocument() throws -> SummaryDocument {
        try JSONDecoder().decode(SummaryDocument.self, from: Data(document.utf8))
    }
}
