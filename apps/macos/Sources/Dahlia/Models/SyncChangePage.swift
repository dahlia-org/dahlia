import Foundation

struct SyncChangePage: Decodable {
    struct Change: Codable, Sendable {
        let sequence: Int
        let entity: SyncEntity
        let entityId: UUID
        let action: String
        let revision: Int?
        let record: SyncCanonicalPayload?
    }

    let items: [Change]
    let cursor: String
    let highWaterCursor: String
    let hasMore: Bool
}
