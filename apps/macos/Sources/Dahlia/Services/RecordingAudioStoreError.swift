import Foundation

enum RecordingAudioStoreError: LocalizedError, Equatable {
    case activeSession
    case activeSegmentSafetyLimit
    case ambiguousFiles
    case diskSpaceLow
    case integrityMismatch
    case invalidPath
    case invalidState
    case missingSessionLease
    case missingFile
    case storageUnavailable
    case writeQueueOverflow

    var errorDescription: String? {
        switch self {
        case .activeSession:
            L10n.recordingAudioSessionActive
        case .activeSegmentSafetyLimit:
            L10n.recordingAudioSafetyLimit
        case .ambiguousFiles:
            L10n.recordingAudioAmbiguous
        case .diskSpaceLow:
            L10n.recordingAudioDiskSpaceLow
        case .integrityMismatch:
            L10n.recordingAudioIntegrityMismatch
        case .invalidPath:
            L10n.recordingAudioInvalidPath
        case .invalidState:
            L10n.recordingAudioInvalidState
        case .missingSessionLease:
            L10n.recordingAudioMissingSessionLease
        case .missingFile:
            L10n.recordingAudioMissing
        case .storageUnavailable:
            L10n.recordingStorageUnavailable
        case .writeQueueOverflow:
            L10n.recordingAudioWriteQueueOverflow
        }
    }
}
