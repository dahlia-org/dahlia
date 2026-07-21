import Foundation

struct BatchLanguageResolution: Sendable {
    let locale: Locale
    let fallback: BatchLanguageFallback?
}

enum BatchLanguageDetectionService {
    private static let inferenceFailureLanguageIdentifier = "en"

    static func resolveLocale(
        audioURL: URL,
        recordedLocaleIdentifiers: [String],
        supportedLocales: [Locale],
        languageDetector: any BatchLanguageDetecting,
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
        } catch BatchLanguageDetectorError.audioLoadingFailed {
            throw BatchSpeechTranscriberError.languageDetectionAudioLoadingFailed
        } catch {
            return try inferenceFailureResolution(supportedLocales: supportedLocales)
        }

        switch outcome {
        case let .detected(languageIdentifier, _):
            let trimmedIdentifier = languageIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedIdentifier.isEmpty else {
                return try inferenceFailureResolution(supportedLocales: supportedLocales)
            }
            if let locale = TranscriptionLocaleResolver.locale(
                forDetectedLanguageIdentifier: trimmedIdentifier,
                recordedLocaleIdentifiers: recordedLocaleIdentifiers,
                supportedLocales: supportedLocales
            ) {
                return BatchLanguageResolution(locale: locale, fallback: nil)
            }
            throw BatchSpeechTranscriberError.unsupportedDetectedLanguage(trimmedIdentifier)
        }
    }

    private static func inferenceFailureResolution(
        supportedLocales: [Locale]
    ) throws -> BatchLanguageResolution {
        guard let englishLocale = TranscriptionLocaleResolver.locale(
            forDetectedLanguageIdentifier: inferenceFailureLanguageIdentifier,
            recordedLocaleIdentifiers: [],
            supportedLocales: supportedLocales
        ) else {
            throw BatchSpeechTranscriberError.unsupportedDetectedLanguage(inferenceFailureLanguageIdentifier)
        }
        return BatchLanguageResolution(
            locale: englishLocale,
            fallback: .inferenceFailure
        )
    }
}
