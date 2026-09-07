import Foundation
import GRDB

struct FileTextBodyRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "file_text_bodies"

    var fileId: UUID
    var ocrText: String?
    var caption: String?
}
