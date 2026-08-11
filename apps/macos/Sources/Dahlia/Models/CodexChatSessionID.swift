import Foundation

struct CodexChatSessionID: Codable, Hashable, Identifiable {
    let rawValue: UUID

    init(rawValue: UUID = .v7()) {
        self.rawValue = rawValue
    }

    var id: UUID { rawValue }
}
