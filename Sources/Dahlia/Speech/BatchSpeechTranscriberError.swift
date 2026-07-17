import Foundation

enum BatchSpeechTranscriberError: LocalizedError {
    case audioFormatUnavailable
    case invalidAudioRange
    case analysisDidNotAdvance

    var errorDescription: String? {
        switch self {
        case .audioFormatUnavailable:
            L10n.batchAudioFormatUnavailable
        case .invalidAudioRange:
            L10n.batchAudioRangeInvalid
        case .analysisDidNotAdvance:
            L10n.batchAnalysisDidNotAdvance
        }
    }
}
