import Foundation

enum TranscriptionLocaleResolver {
    private static let preferredFallbacksByLanguage = [
        "en": "en_US",
        "ja": "ja_JP",
    ]

    static func resolvedSupportedLocaleIdentifier(
        preferredIdentifier: String,
        supportedLocales: [Locale]
    ) -> String {
        let trimmedIdentifier = preferredIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedIdentifier = normalizedLocaleIdentifier(from: trimmedIdentifier)
        let supportedLocaleIdentifiers = Set(supportedLocales.map(\.identifier))

        if supportedLocaleIdentifiers.contains(normalizedIdentifier) {
            return normalizedIdentifier
        }

        let preferredLanguageIdentifier = TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: trimmedIdentifier)
        if let preferredFallback = preferredFallbacksByLanguage[preferredLanguageIdentifier],
           supportedLocaleIdentifiers.contains(preferredFallback) {
            return preferredFallback
        }

        let sortedLocales = supportedLocales.sorted(by: { $0.identifier < $1.identifier })
        if let sameLanguageLocale = sortedLocales.first(where: {
            TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: $0.identifier) == preferredLanguageIdentifier
        }) {
            return sameLanguageLocale.identifier
        }

        for fallback in preferredFallbacksByLanguage.values.sorted() where supportedLocaleIdentifiers.contains(fallback) {
            return fallback
        }
        return sortedLocales.first?.identifier ?? normalizedIdentifier
    }

    static func locale(
        forDetectedLanguageIdentifier detectedLanguageIdentifier: String,
        recordedLocaleIdentifiers: [String],
        supportedLocales: [Locale]
    ) -> Locale? {
        let detectedLanguage = TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: detectedLanguageIdentifier)
        guard !detectedLanguage.isEmpty else { return nil }

        let candidates = supportedLocales
            .filter {
                TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: $0.identifier) == detectedLanguage
            }
            .sorted(by: { $0.identifier < $1.identifier })
        guard !candidates.isEmpty else { return nil }

        for recordedLocaleIdentifier in recordedLocaleIdentifiers
            where TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: recordedLocaleIdentifier) == detectedLanguage {
            let normalizedRecordedIdentifier = normalizedLocaleIdentifier(from: recordedLocaleIdentifier)
            if let recordedLocale = candidates.first(where: { $0.identifier == normalizedRecordedIdentifier }) {
                return recordedLocale
            }
        }

        if let preferredFallback = preferredFallbacksByLanguage[detectedLanguage],
           let fallbackLocale = candidates.first(where: { $0.identifier == preferredFallback }) {
            return fallbackLocale
        }
        return candidates.first
    }

    private static func normalizedLocaleIdentifier(from identifier: String) -> String {
        guard !identifier.isEmpty else { return identifier }

        let locale = Locale(identifier: identifier)
        guard let languageCode = locale.language.languageCode?.identifier.nilIfBlank else {
            return identifier
                .replacing("-", with: "_")
                .split(separator: "@", maxSplits: 1)
                .first
                .map(String.init) ?? identifier
        }
        guard let regionCode = locale.region?.identifier.nilIfBlank else { return languageCode }
        return "\(languageCode)_\(regionCode)"
    }
}
