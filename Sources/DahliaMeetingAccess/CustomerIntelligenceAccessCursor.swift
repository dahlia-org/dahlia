import Foundation

struct CustomerTextCursor: Codable {
    let vaultID: UUID
    let scope: String
    let sortKey: String
    let id: UUID

    func encoded() -> String {
        (try? JSONEncoder().encode(self).base64EncodedString()) ?? ""
    }

    static func decode(_ value: String, vaultID: UUID, scope: String) throws -> Self {
        guard let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(Self.self, from: data),
              cursor.vaultID == vaultID,
              cursor.scope == scope
        else {
            throw MeetingAccessError.invalidCursor
        }
        return cursor
    }
}

struct CustomerDateCursor: Codable {
    let vaultID: UUID
    let scope: String
    let date: Date
    let id: UUID

    func encoded() -> String {
        (try? JSONEncoder().encode(self).base64EncodedString()) ?? ""
    }

    static func decode(_ value: String, vaultID: UUID, scope: String) throws -> Self {
        guard let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(Self.self, from: data),
              cursor.vaultID == vaultID,
              cursor.scope == scope
        else {
            throw MeetingAccessError.invalidCursor
        }
        return cursor
    }
}
