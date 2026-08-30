import Foundation

enum AccessCursorCodec {
    static func encode(_ cursor: some Encodable) -> String {
        (try? JSONEncoder().encode(cursor).base64EncodedString()) ?? ""
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        from value: String,
        isValid: (T) -> Bool
    ) throws -> T {
        guard let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(type, from: data),
              isValid(cursor)
        else {
            throw MeetingAccessError.invalidCursor
        }
        return cursor
    }
}

struct CustomerTextCursor: Codable {
    let vaultID: UUID
    let scope: String
    let sortKey: String
    let id: UUID

    func encoded() -> String {
        AccessCursorCodec.encode(self)
    }

    static func decode(_ value: String, vaultID: UUID, scope: String) throws -> Self {
        try AccessCursorCodec.decode(Self.self, from: value) { cursor in
            cursor.vaultID == vaultID && cursor.scope == scope
        }
    }
}

struct CustomerDateCursor: Codable {
    let vaultID: UUID
    let scope: String
    let date: Date
    let id: UUID

    func encoded() -> String {
        AccessCursorCodec.encode(self)
    }

    static func decode(_ value: String, vaultID: UUID, scope: String) throws -> Self {
        try AccessCursorCodec.decode(Self.self, from: value) { cursor in
            cursor.vaultID == vaultID && cursor.scope == scope
        }
    }
}
