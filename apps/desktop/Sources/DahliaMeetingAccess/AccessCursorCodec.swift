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
