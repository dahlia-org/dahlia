import GRDB

enum RecordingAudioRetentionPolicy: String, Codable, CaseIterable, DatabaseValueConvertible {
    case deleteAfterTranscription
    case keepInApp
}
