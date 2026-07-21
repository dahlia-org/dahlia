import Foundation

struct BatchLanguageDetectionCandidateSnapshot: Codable, Equatable, Sendable {
    let scope: TranscriptionLanguageScope
    let languageIdentifiers: [String]

    init(scope: TranscriptionLanguageScope, languageIdentifiers: Set<String>) {
        self.scope = scope
        self.languageIdentifiers = Set(
            languageIdentifiers.compactMap(WhisperLanguageIdentifier.supportedCanonicalIdentifier)
        ).sorted()
    }

    var identifierSet: Set<String> { Set(languageIdentifiers) }

    func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return encoded
    }

    static func decode(_ encoded: String) throws -> Self {
        guard let data = encoded.data(using: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        return Self(scope: decoded.scope, languageIdentifiers: Set(decoded.languageIdentifiers))
    }
}

struct BatchLanguageDetectionCandidates: Equatable, Sendable {
    let snapshot: BatchLanguageDetectionCandidateSnapshot
    let locales: [Locale]
}

enum BatchLanguageDetectionCandidateResolver {
    static func candidates(
        scope: TranscriptionLanguageScope,
        enabledLocaleIdentifiers: Set<String>,
        supportedLocales: [Locale]
    ) -> BatchLanguageDetectionCandidates {
        let eligibleLocales = supportedLocales.filter { locale in
            scope == .all || enabledLocaleIdentifiers.contains(locale.identifier)
        }
        var languageIdentifiers: Set<String> = []
        let candidateLocales = eligibleLocales.filter { locale in
            guard let languageIdentifier = WhisperLanguageIdentifier.supportedCanonicalIdentifier(
                from: locale.identifier
            ) else { return false }
            return languageIdentifiers.insert(languageIdentifier).inserted
        }
        return BatchLanguageDetectionCandidates(
            snapshot: BatchLanguageDetectionCandidateSnapshot(
                scope: scope,
                languageIdentifiers: languageIdentifiers
            ),
            locales: candidateLocales
        )
    }

    static func candidates(
        snapshot: BatchLanguageDetectionCandidateSnapshot,
        supportedLocales: [Locale]
    ) -> BatchLanguageDetectionCandidates {
        var remainingIdentifiers = snapshot.identifierSet
        let candidateLocales = supportedLocales.filter { locale in
            guard let languageIdentifier = WhisperLanguageIdentifier.supportedCanonicalIdentifier(
                from: locale.identifier
            ) else { return false }
            return remainingIdentifiers.remove(languageIdentifier) != nil
        }
        return BatchLanguageDetectionCandidates(snapshot: snapshot, locales: candidateLocales)
    }
}
