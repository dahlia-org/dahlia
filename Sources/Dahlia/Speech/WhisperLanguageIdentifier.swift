import Foundation

/// Bridges BCP-47 language codes used by Apple APIs to Whisper's historical token codes.
enum WhisperLanguageIdentifier {
    static func canonicalIdentifier(from identifier: String) -> String? {
        let languageIdentifier = TranscriptTranslationLanguage
            .normalizedLanguageIdentifier(from: identifier)
            .lowercased()
            .nilIfBlank
        guard let languageIdentifier else { return nil }
        return switch languageIdentifier {
        case "nb": "no"
        case "fil": "tl"
        case "jv": "jw"
        default: languageIdentifier
        }
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhs = canonicalIdentifier(from: lhs),
              let rhs = canonicalIdentifier(from: rhs) else { return false }
        return lhs == rhs
    }
}
