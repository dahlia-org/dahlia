import Foundation

struct BatchLanguageResolution: Sendable {
    let locale: Locale
    let fallback: BatchLanguageFallback?
}

enum BatchLanguageDetectionService {
    static let minimumTopProbability: Float = 0.5

    static func resolveLocale(
        audioURL: URL,
        recordedLocaleIdentifiers: [String],
        supportedLocales: [Locale],
        languageDetector: any BatchLanguageDetecting,
        fallbackLocaleIdentifier: String,
        allowedLanguageIdentifiers: Set<String>? = nil
    ) async throws -> BatchLanguageResolution {
        let outcome: BatchLanguageDetectionOutcome
        do {
            outcome = try await languageDetector.detectLanguage(
                audioURL: audioURL,
                allowedLanguageIdentifiers: allowedLanguageIdentifiers
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch BatchLanguageDetectorError.modelPreparationFailed {
            throw BatchSpeechTranscriberError.languageModelPreparationFailed
        } catch {
            return try fallbackResolution(
                reason: .detectionFailed,
                detectedLanguageIdentifier: nil,
                topProbability: nil,
                fallbackLocaleIdentifier: fallbackLocaleIdentifier,
                supportedLocales: supportedLocales
            )
        }

        switch outcome {
        case let .detected(languageIdentifier, logProbability):
            let trimmedIdentifier = languageIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedIdentifier.isEmpty else {
                return try fallbackResolution(
                    reason: .detectionFailed,
                    detectedLanguageIdentifier: nil,
                    topProbability: nil,
                    fallbackLocaleIdentifier: fallbackLocaleIdentifier,
                    supportedLocales: supportedLocales
                )
            }
            let topProbability = probability(fromLogProbability: logProbability)
            guard let topProbability, topProbability >= minimumTopProbability else {
                return try fallbackResolution(
                    reason: .lowConfidence,
                    detectedLanguageIdentifier: trimmedIdentifier,
                    topProbability: topProbability,
                    fallbackLocaleIdentifier: fallbackLocaleIdentifier,
                    supportedLocales: supportedLocales
                )
            }
            if let locale = TranscriptionLocaleResolver.locale(
                forDetectedLanguageIdentifier: trimmedIdentifier,
                recordedLocaleIdentifiers: [fallbackLocaleIdentifier] + recordedLocaleIdentifiers,
                supportedLocales: supportedLocales
            ) {
                return BatchLanguageResolution(locale: locale, fallback: nil)
            }
            return try fallbackResolution(
                reason: .unsupportedLanguage,
                detectedLanguageIdentifier: trimmedIdentifier,
                topProbability: topProbability,
                fallbackLocaleIdentifier: fallbackLocaleIdentifier,
                supportedLocales: supportedLocales
            )
        }
    }

    private static func probability(fromLogProbability logProbability: Float?) -> Float? {
        guard let logProbability, logProbability.isFinite else { return nil }
        return min(max(exp(logProbability), 0), 1)
    }

    private static func fallbackResolution(
        reason: BatchLanguageFallback.Reason,
        detectedLanguageIdentifier: String?,
        topProbability: Float?,
        fallbackLocaleIdentifier: String,
        supportedLocales: [Locale]
    ) throws -> BatchLanguageResolution {
        guard let fallbackLocale = TranscriptionLocaleResolver.locale(
            forDetectedLanguageIdentifier: fallbackLocaleIdentifier,
            recordedLocaleIdentifiers: [fallbackLocaleIdentifier],
            supportedLocales: supportedLocales
        ) else {
            throw BatchSpeechTranscriberError.unsupportedDetectedLanguage(fallbackLocaleIdentifier)
        }
        return BatchLanguageResolution(
            locale: fallbackLocale,
            fallback: BatchLanguageFallback(
                reason: reason,
                detectedLanguageIdentifier: detectedLanguageIdentifier,
                fallbackLocaleIdentifier: fallbackLocale.identifier,
                topProbability: topProbability
            )
        )
    }
}
