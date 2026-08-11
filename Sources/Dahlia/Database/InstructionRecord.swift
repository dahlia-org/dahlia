import Foundation
import GRDB

/// 要約用 instructions を表す GRDB レコード。
struct InstructionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "instructions"

    var id: UUID
    var vaultId: UUID
    var name: String
    var content: String
    var createdAt: Date
    var updatedAt: Date

    var displayName: String { name.replacingOccurrences(of: "_", with: " ") }
}
