import Foundation

enum BatchLanguageDetectionService {
    static func resolveLocale(
        audioURL: URL,
        recordedLocaleIdentifiers: [String],
        supportedLocales: [Locale],
        languageDetector: any BatchLanguageDetecting
    ) async throws -> Locale {
        let languageIdentifier: String
        do {
            languageIdentifier = try await languageDetector.detectLanguage(audioURL: audioURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch BatchLanguageDetectorError.modelPreparationFailed {
            throw BatchSpeechTranscriberError.languageModelPreparationFailed
        } catch {
            throw BatchSpeechTranscriberError.languageDetectionFailed
        }
        guard let locale = TranscriptionLocaleResolver.locale(
            forDetectedLanguageIdentifier: languageIdentifier,
            recordedLocaleIdentifiers: recordedLocaleIdentifiers,
            supportedLocales: supportedLocales
        ) else {
            throw BatchSpeechTranscriberError.unsupportedDetectedLanguage(languageIdentifier)
        }
        return locale
    }
}
