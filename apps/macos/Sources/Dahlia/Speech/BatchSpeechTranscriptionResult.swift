import Foundation

struct BatchSpeechTranscriptionResult: Sendable {
    let segments: [TranscriptSegment]
    let localeIdentifier: String
    let languageFallback: BatchLanguageFallback?
}
