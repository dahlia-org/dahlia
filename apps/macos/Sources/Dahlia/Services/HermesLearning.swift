import Foundation

/// Pinned upstream text. Changes belong in PiExtension/hermes/UPSTREAM.md.
enum HermesLearning {
    static let prompts: [String: String] = {
        guard let data = try? Data(contentsOf: PiBundle.resourceURL("hermes/prompts.json")),
              let result = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return result
    }()

    private struct Threats: Decodable {
        var patterns: [[String]]
        var invisible: [UInt32]
    }

    private static let threats: Threats? = {
        guard let data = try? Data(contentsOf: PiBundle.resourceURL("hermes/threat-patterns.json")) else { return nil }
        return try? JSONDecoder().decode(Threats.self, from: data)
    }()

    static func validate(_ content: String) throws {
        guard let threats else { throw failure("Hermes threat patterns are unavailable.") }
        // The upstream RGI emoji subdivision flags contain otherwise invisible tag characters.
        var raw = content
        for flag in ["gbeng", "gbsct", "gbwls"] {
            let scalars = [UnicodeScalar(0x1F3F4)!] + flag.unicodeScalars.map { UnicodeScalar($0.value + 0xE0000)! } + [UnicodeScalar(0xE007F)!]
            raw = raw.replacingOccurrences(of: String(String.UnicodeScalarView(scalars)), with: "")
        }
        let invisible = Set(threats.invisible)
        if raw.unicodeScalars.contains(where: { invisible.contains($0.value) }) {
            throw failure("Blocked: content contains invisible Unicode characters (possible injection).")
        }
        let normalized = content.precomposedStringWithCompatibilityMapping
        let whitespace = try NSRegularExpression(pattern: "\\s{2,}")
        let mutable = NSMutableString(string: normalized)
        for match in whitespace.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)).reversed() {
            let replacement = mutable.substring(with: match.range).contains("\n") ? "\n" : " "
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        let text = mutable as String
        for pattern in threats.patterns {
            // ICU and Python share these bounded expressions; inline Python flags are converted at vendoring time.
            let expression = try NSRegularExpression(pattern: pattern[0], options: [.caseInsensitive])
            if expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                throw failure("Blocked: content matches threat pattern '\(pattern[1])'.")
            }
        }
    }

    static func failure(_ message: String)
        -> NSError { NSError(domain: "DahliaAgentLearning", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func count(_ text: String) -> Int { text.unicodeScalars.count }
    static func json(_ value: some Encodable) throws -> String {
        try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
    }
}
