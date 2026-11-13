import Foundation

enum SearchUserDictionaryCSV {
    static func validate(_ data: Data) throws -> Bool {
        guard data.count <= 10 * 1024 * 1024, var text = String(data: data, encoding: .utf8) else {
            throw SearchDictionaryError.invalidUserDictionary
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var hasEntries = false
        var fields: [String] = []
        var field = ""
        var quoted = false
        var closedQuote = false

        func finishField() {
            fields.append(field)
            field = ""
            closedQuote = false
        }

        func finishRow() throws {
            finishField()
            if fields != [""] {
                guard fields.count == 3 || fields.count == 13 else { throw SearchDictionaryError.invalidUserDictionary }
                let indices = fields.count == 3 ? [0, 1, 2] : [0, 4, 11]
                guard indices.allSatisfy({ !fields[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw SearchDictionaryError.invalidUserDictionary
                }
                hasEntries = true
            }
            fields = []
        }

        for character in text {
            if quoted {
                if character == "\"" {
                    quoted = false
                    closedQuote = true
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    guard field.isEmpty || closedQuote else { throw SearchDictionaryError.invalidUserDictionary }
                    if closedQuote { field.append("\"") }
                    quoted = true
                    closedQuote = false
                case ",": finishField()
                case "\n", "\r", "\r\n": try finishRow()
                default:
                    guard !closedQuote else { throw SearchDictionaryError.invalidUserDictionary }
                    field.append(character)
                }
            }
        }
        guard !quoted else { throw SearchDictionaryError.invalidUserDictionary }
        if !fields.isEmpty || !field.isEmpty || closedQuote { try finishRow() }
        return hasEntries
    }

}
