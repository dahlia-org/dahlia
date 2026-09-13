import Foundation
import GRDB

/// 要約用 instructions を表す GRDB レコード。
struct InstructionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "instructions"

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceId = "workspace_id"
        case name
        case content
        case createdAt
        case updatedAt
    }

    var id: UUID
    var workspaceId: UUID
    var name: String
    var content: String
    var createdAt: Date
    var updatedAt: Date

    var displayName: String { name.replacingOccurrences(of: "_", with: " ") }
}
