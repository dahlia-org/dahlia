import Foundation
import GRDB

struct DahliaAccountConnectionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "dahlia_account_connections"

    var id: UUID
    var origin: String
    var clientID: String
    var createdAt: Date
}
