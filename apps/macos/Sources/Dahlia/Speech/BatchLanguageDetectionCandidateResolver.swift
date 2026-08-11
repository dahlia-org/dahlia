import Foundation

struct BatchLanguageDetectionCandidateSnapshot: Codable, Equatable, Sendable {
    let scope: TranscriptionLanguageScope
    let languageIdentifiers: [String]
    let localeIdentifiers: [String]

    init(
        scope: TranscriptionLanguageScope,
        languageIdentifiers: Set<String>,
        localeIdentifiers: [String] = []
    ) {
        self.scope = scope
        let normalizedLanguageIdentifiers = Set(
            languageIdentifiers.compactMap(WhisperLanguageIdentifier.supportedCanonicalIdentifier)
        )
        self.languageIdentifiers = normalizedLanguageIdentifiers.sorted()
        var includedLanguageIdentifiers: Set<String> = []
        self.localeIdentifiers = localeIdentifiers.filter { localeIdentifier in
            guard let languageIdentifier = WhisperLanguageIdentifier.supportedCanonicalIdentifier(
                from: localeIdentifier
            ), normalizedLanguageIdentifiers.contains(languageIdentifier) else { return false }
            return includedLanguageIdentifiers.insert(languageIdentifier).inserted
        }
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
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case scope
        case languageIdentifiers
        case localeIdentifiers
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scope: container.decode(TranscriptionLanguageScope.self, forKey: .scope),
            languageIdentifiers: Set(container.decode([String].self, forKey: .languageIdentifiers)),
            localeIdentifiers: container.decodeIfPresent([String].self, forKey: .localeIdentifiers) ?? []
        )
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
                languageIdentifiers: languageIdentifiers,
                localeIdentifiers: candidateLocales.map(\.identifier)
            ),
            locales: candidateLocales
        )
    }

    static func candidates(
        snapshot: BatchLanguageDetectionCandidateSnapshot,
        supportedLocales: [Locale]
    ) -> BatchLanguageDetectionCandidates {
        var remainingIdentifiers = snapshot.identifierSet
        var candidateLocales: [Locale] = []
        for localeIdentifier in snapshot.localeIdentifiers {
            guard let locale = supportedLocales.first(where: { $0.identifier == localeIdentifier }),
                  let languageIdentifier = WhisperLanguageIdentifier.supportedCanonicalIdentifier(
                      from: locale.identifier
                  ), remainingIdentifiers.remove(languageIdentifier) != nil else { continue }
            candidateLocales.append(locale)
        }
        candidateLocales.append(contentsOf: supportedLocales.filter { locale in
            guard let languageIdentifier = WhisperLanguageIdentifier.supportedCanonicalIdentifier(
                from: locale.identifier
            ) else { return false }
            return remainingIdentifiers.remove(languageIdentifier) != nil
        })
        return BatchLanguageDetectionCandidates(snapshot: snapshot, locales: candidateLocales)
    }
}
