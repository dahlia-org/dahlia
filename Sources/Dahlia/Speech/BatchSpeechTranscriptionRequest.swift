import Foundation

struct BatchSpeechTranscriptionRequest: Sendable {
    let audioURL: URL
    let startFrame: Int64
    let frameCount: Int64
    let recordedLocaleIdentifiers: [String]
    let supportedLocales: [Locale]
    let automaticLanguageCandidateLocales: [Locale]?
    /// `nil` means unrestricted Whisper detection; a non-nil set contains canonical
    /// Whisper language codes and is never interpreted as a preference order.
    let allowedLanguageIdentifiers: Set<String>?

    init(
        audioURL: URL,
        startFrame: Int64,
        frameCount: Int64,
        recordedLocaleIdentifiers: [String],
        supportedLocales: [Locale],
        automaticLanguageCandidateLocales: [Locale]? = nil,
        allowedLanguageIdentifiers: Set<String>? = nil
    ) {
        self.audioURL = audioURL
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.recordedLocaleIdentifiers = recordedLocaleIdentifiers
        self.supportedLocales = supportedLocales
        self.automaticLanguageCandidateLocales = automaticLanguageCandidateLocales
        self.allowedLanguageIdentifiers = allowedLanguageIdentifiers
    }
}
