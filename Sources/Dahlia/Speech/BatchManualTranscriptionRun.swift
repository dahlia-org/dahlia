import Foundation

struct BatchManualTranscriptionRun: Sendable {
    let slices: [BatchSpeechAudioSlice]
    let sliceFileIndices: [Int]
    let localeIdentifier: String
    let source: RecordingAudioSource
    let recordingSessionId: UUID
    let recordingStartTime: Date
    let sessionOffsetSeconds: TimeInterval
    let fileIndices: [Int]
}
