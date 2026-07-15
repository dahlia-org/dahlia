import GRDB

enum RecordingAudioSegmentState: String, Codable, CaseIterable, DatabaseValueConvertible {
    case recording
    case finalizing
    case ready
    case purgePending
    case purged
    case failed
}
