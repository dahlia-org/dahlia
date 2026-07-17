import Foundation
import os
import Translation

actor TranscriptTranslationService {
    private struct LanguagePair: Hashable {
        let sourceLanguageIdentifier: String
        let targetLanguageIdentifier: String
    }

    private let logger = Logger(subsystem: "com.dahlia", category: "TranscriptTranslation")

    private var availabilityStatuses: [LanguagePair: LanguageAvailability.Status] = [:]

    func translate(
        _ text: String,
        from sourceLocaleIdentifier: String,
        to targetLanguageIdentifier: String
    ) async -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        let sourceLanguage = Locale(identifier: sourceLocaleIdentifier).language
        let targetLanguage = Locale.Language(
            identifier: TranscriptTranslationLanguage.normalizedLanguageIdentifier(from: targetLanguageIdentifier)
        )
        guard await isSupportedLanguagePair(source: sourceLanguage, target: targetLanguage) else {
            return nil
        }

        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)

        do {
            let response = try await session.translate(trimmedText)
            return response.targetText.nilIfBlank
        } catch {
            logger.error("Translation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func isSupportedLanguagePair(source: Locale.Language, target: Locale.Language) async -> Bool {
        let pair = LanguagePair(
            sourceLanguageIdentifier: source.maximalIdentifier,
            targetLanguageIdentifier: target.maximalIdentifier
        )

        if let availabilityStatus = availabilityStatuses[pair] {
            return availabilityStatus != .unsupported
        }

        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)
        availabilityStatuses[pair] = status
        if status == .unsupported {
            logger.warning(
                "Translation is unsupported for \(pair.sourceLanguageIdentifier, privacy: .public) -> \(pair.targetLanguageIdentifier, privacy: .public)"
            )
        }
        return status != .unsupported
    }
}
