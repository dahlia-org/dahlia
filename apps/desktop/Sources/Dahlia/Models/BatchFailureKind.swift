import GRDB

enum BatchFailureKind: String, Codable, DatabaseValueConvertible, Sendable {
    case recordingStorage
    case recordingRecovery
    case recordingAudioPermanent
    case transcription
    case transcriptionStalled
    case transcriptionInterrupted
}
