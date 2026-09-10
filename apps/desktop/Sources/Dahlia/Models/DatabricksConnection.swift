import Foundation

struct DatabricksConnection: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let host: String
}
