import Foundation

enum BatchLanguageDetectorError: Error, Sendable {
    case modelPreparationFailed
    case audioLoadingFailed
    case inferenceFailed
}

enum BatchLanguageDetectionOutcome: Sendable, Equatable {
    case detected(
        languageIdentifier: String,
        logProbability: Float?
    )
}

enum BatchLanguageFallback: Sendable, Equatable {
    case inferenceFailure
}

protocol BatchLanguageDetecting: Sendable {
    /// `nil` allows every Whisper language. A non-nil set contains language codes rather
    /// than regional locale identifiers; an empty/unsupported set produces an inference
    /// failure and the caller treats the audio as English.
    func detectLanguage(
        audioURL: URL,
        allowedLanguageIdentifiers: Set<String>?
    ) async throws -> BatchLanguageDetectionOutcome
    func unload() async
}
