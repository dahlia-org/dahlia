import Foundation

struct BatchSpeechTranscriptionRequest {
    let audioURL: URL
    let startFrame: Int64
    let frameCount: Int64
    let recordedLocaleIdentifiers: [String]
    let languageDetectionMode: BatchLanguageDetectionMode
    let supportedLocales: [Locale]
    let source: RecordingAudioSource
    let recordingSessionId: UUID
    let recordingStartTime: Date
    let sessionOffsetSeconds: TimeInterval
}
