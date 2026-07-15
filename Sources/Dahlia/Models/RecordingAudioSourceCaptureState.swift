import GRDB

enum RecordingAudioSourceCaptureState: String, Codable, CaseIterable, DatabaseValueConvertible {
    case planned
    case active
    case ended
    case failed
}
