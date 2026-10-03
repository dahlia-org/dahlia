import Foundation
import GRDB

struct TagRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable {
    static let databaseTableName = "tags"

    var id: Int64?
    var name: String
    var colorHex: String
    var createdAt: Date
}
