import DahliaRuntimeSupport
import Foundation
import GRDB

struct ChatItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "chat_items"
    static func messagePredicate(dataColumn: String = "data") -> String {
        """
        json_extract(\(dataColumn), '$.type') = 'message'
        AND json_extract(\(dataColumn), '$.role') IN ('user', 'assistant')
        AND (COALESCE(json_extract(\(dataColumn), '$.content'), '') <> ''
            OR COALESCE(json_extract(\(dataColumn), '$.reasoning'), '') <> ''
            OR json_array_length(\(dataColumn), '$.images') > 0)
        """
    }

    var id: UUID
    var threadID: String
    var seq: Int64
    var data: String
    var createdAt: Date
}
