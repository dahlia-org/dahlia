import Foundation

enum BatchLanguageDetectionCandidateResolver {
    static func languageIdentifiers(
        scope: TranscriptionLanguageScope,
        enabledLocaleIdentifiers: Set<String>,
        fallbackLocaleIdentifier: String
    ) -> Set<String>? {
        guard scope == .selected else { return nil }

        var identifiers = Set(enabledLocaleIdentifiers.compactMap(WhisperLanguageIdentifier.canonicalIdentifier))
        if let fallbackIdentifier = WhisperLanguageIdentifier.canonicalIdentifier(from: fallbackLocaleIdentifier) {
            identifiers.insert(fallbackIdentifier)
        }
        return identifiers
    }
}
