import Foundation

public enum DahliaProjectName {
    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")

    /// Stable sibling identity shared by the app, database migration, sync, and MCP.
    public static func siblingKey(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: normalizationLocale)
    }

    public static func normalizedLeafName(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.hasPrefix("."),
              !value.hasPrefix("_"),
              !value.contains("/"),
              !value.contains(":"),
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              value.utf8.count <= 255 else {
            return nil
        }
        return value
    }

    public static func migrationSafeLeafName(_ value: String, suffix: String = "") -> String {
        var base = String(value.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) {
                return "-"
            }
            return Character(String(scalar))
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || base == "." || base == ".." {
            base = "Project"
        } else if base.hasPrefix(".") || base.hasPrefix("_") {
            base = "Project \(base)"
        }
        while (base + suffix).utf8.count > 255, !base.isEmpty {
            base.removeLast()
        }
        return base + suffix
    }
}
