import Foundation

struct BatchSpeechTranscriptionRequest: Sendable {
    let audioURL: URL
    let startFrame: Int64
    let frameCount: Int64
    let recordedLocaleIdentifiers: [String]
    let languageDetectionMode: BatchLanguageDetectionMode
    let supportedLocales: [Locale]
    /// `nil` means unrestricted Whisper detection; a non-nil set contains canonical
    /// Whisper language codes and is never interpreted as a preference order.
    let allowedLanguageIdentifiers: Set<String>?
    let source: RecordingAudioSource
    let recordingSessionId: UUID
    let recordingStartTime: Date
    let sessionOffsetSeconds: TimeInterval

    init(
        audioURL: URL,
        startFrame: Int64,
        frameCount: Int64,
        recordedLocaleIdentifiers: [String],
        languageDetectionMode: BatchLanguageDetectionMode,
        supportedLocales: [Locale],
        allowedLanguageIdentifiers: Set<String>? = nil,
        source: RecordingAudioSource,
        recordingSessionId: UUID,
        recordingStartTime: Date,
        sessionOffsetSeconds: TimeInterval
    ) {
        self.audioURL = audioURL
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.recordedLocaleIdentifiers = recordedLocaleIdentifiers
        self.languageDetectionMode = languageDetectionMode
        self.supportedLocales = supportedLocales
        self.allowedLanguageIdentifiers = allowedLanguageIdentifiers
        self.source = source
        self.recordingSessionId = recordingSessionId
        self.recordingStartTime = recordingStartTime
        self.sessionOffsetSeconds = sessionOffsetSeconds
    }
}
