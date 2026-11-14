import DahliaRuntimeSupport
import Foundation

/// Store-assigned identity; remote item IDs and cursors are opaque to callers.
struct ChatItem: Sendable {
    let id: String
    let data: JSONValue
    let createdAt: Date
}

extension ChatItem {
    init(_ record: ChatItemRecord) throws {
        try self.init(
            id: record.id.uuidString.lowercased(),
            data: JSONDecoder().decode(JSONValue.self, from: Data(record.data.utf8)),
            createdAt: record.createdAt
        )
    }
}
