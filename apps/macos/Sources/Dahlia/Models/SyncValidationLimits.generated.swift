/// Generated from the Server validation contract. Run pnpm openapi:generate.
enum SyncValidationLimits {
    static let fileOCRText = 32768
    static let fileCaption = 1024

    static func prefix(_ value: String, maxCodePointCount: Int) -> String {
        guard value.unicodeScalars.count > maxCodePointCount else { return value }
        var codePointCount = 0
        let boundary = value.firstIndex { character in
            codePointCount += character.unicodeScalars.count
            return codePointCount > maxCodePointCount
        }
        return String(value[..<(boundary ?? value.endIndex)])
    }
}
