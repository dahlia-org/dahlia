import Foundation

enum BatchLanguageDetectorError: Error, Sendable {
    case modelPreparationFailed
    case detectionFailed
}

enum BatchLanguageDetectionOutcome: Sendable, Equatable {
    case detected(
        languageIdentifier: String,
        logProbability: Float?
    )

}

struct BatchLanguageFallback: Sendable, Equatable {
    enum Reason: String, Sendable {
        case detectionFailed
        case lowConfidence
        case unsupportedLanguage
    }

    let reason: Reason
    let detectedLanguageIdentifier: String?
    let fallbackLocaleIdentifier: String
    let topProbability: Float?
}

protocol BatchLanguageDetecting: Sendable {
    /// `nil` allows every Whisper language. A non-nil set contains language codes rather
    /// than regional locale identifiers; an empty/unsupported set produces a detection
    /// failure so the caller can use its explicitly selected fallback locale.
    func detectLanguage(
        audioURL: URL,
        allowedLanguageIdentifiers: Set<String>?
    ) async throws -> BatchLanguageDetectionOutcome
    func unload() async
}
