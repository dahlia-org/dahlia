import Foundation

struct TranscriptTranslationLanguageOption: Identifiable, Equatable {
    let identifier: String
    let displayName: String

    var id: String { identifier }
}

enum TranscriptTranslationLanguage {
    nonisolated static let defaultIdentifier = "ja"

    static func normalizedLanguageIdentifier(from identifier: String) -> String {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty else { return "" }

        let normalizedIdentifier = trimmedIdentifier.replacingOccurrences(of: "_", with: "-")
        let locale = Locale(identifier: normalizedIdentifier)
        if let languageCode = locale.language.languageCode?.identifier.nilIfBlank {
            return languageCode.lowercased()
        }

        return normalizedIdentifier
            .split(separator: "-", maxSplits: 1)
            .first
            .map { String($0).lowercased() } ?? normalizedIdentifier.lowercased()
    }

    static func shouldTranslate(
        transcriptionLocaleIdentifier: String,
        targetLanguageIdentifier: String
    ) -> Bool {
        let sourceLanguageIdentifier = normalizedLanguageIdentifier(from: transcriptionLocaleIdentifier)
        let targetLanguageIdentifier = normalizedLanguageIdentifier(from: targetLanguageIdentifier)
        guard !sourceLanguageIdentifier.isEmpty, !targetLanguageIdentifier.isEmpty else {
            return false
        }
        return sourceLanguageIdentifier != targetLanguageIdentifier
    }

    static func displayName(for identifier: String, locale: Locale = .current) -> String {
        let normalizedIdentifier = normalizedLanguageIdentifier(from: identifier)
        guard !normalizedIdentifier.isEmpty else { return identifier }
        return locale.localizedString(forLanguageCode: normalizedIdentifier) ?? normalizedIdentifier
    }

    static func availableTargetLanguages(from locales: [Locale], locale: Locale = .current) -> [TranscriptTranslationLanguageOption] {
        var seenIdentifiers = Set<String>()
        var options: [TranscriptTranslationLanguageOption] = []

        for sourceLocale in locales {
            let normalizedIdentifier = normalizedLanguageIdentifier(from: sourceLocale.identifier)
            guard !normalizedIdentifier.isEmpty, seenIdentifiers.insert(normalizedIdentifier).inserted else {
                continue
            }

            options.append(
                TranscriptTranslationLanguageOption(
                    identifier: normalizedIdentifier,
                    displayName: displayName(for: normalizedIdentifier, locale: locale)
                )
            )
        }

        return options.sorted {
            $0.displayName.compare($1.displayName, locale: locale) == .orderedAscending
        }
    }
}
