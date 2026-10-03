import Foundation

enum RecordingSessionControllerError: LocalizedError {
    case sessionAlreadyActive
    case sessionNotActive
    case sessionNotPrepared
    case invalidBatchConfiguration
    case noAudioSource
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive:
            L10n.recordingSessionAlreadyActive
        case .sessionNotActive:
            L10n.recordingSessionNotActive
        case .sessionNotPrepared:
            L10n.speechRecognitionNotReady
        case .invalidBatchConfiguration:
            L10n.batchAudioFormatUnavailable
        case .noAudioSource:
            L10n.noAudioSourceSelected
        case let .recognitionFailed(message):
            message
        }
    }
}
