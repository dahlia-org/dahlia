import GRDB

enum BatchFailureKind: String, Codable, DatabaseValueConvertible {
    case recordingStorage
    case recordingRecovery
    case recordingAudioPermanent
    case transcription
}
