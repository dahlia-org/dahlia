import Foundation

struct DatabricksConnection: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let host: String
}
