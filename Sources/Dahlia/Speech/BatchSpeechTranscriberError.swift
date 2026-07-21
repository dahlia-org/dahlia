import Foundation

enum BatchSpeechTranscriberError: LocalizedError {
    case audioFormatUnavailable
    case invalidAudioRange
    case analysisDidNotAdvance
    case languageModelPreparationFailed
    case languageDetectionFailed
    case unsupportedDetectedLanguage(String)

    var errorDescription: String? {
        switch self {
        case .audioFormatUnavailable:
            L10n.batchAudioFormatUnavailable
        case .invalidAudioRange:
            L10n.batchAudioRangeInvalid
        case .analysisDidNotAdvance:
            L10n.batchAnalysisDidNotAdvance
        case .languageModelPreparationFailed:
            L10n.batchLanguageModelPreparationFailed
        case .languageDetectionFailed:
            L10n.batchLanguageDetectionFailed
        case let .unsupportedDetectedLanguage(languageIdentifier):
            L10n.batchDetectedLanguageUnsupported(languageIdentifier)
        }
    }
}
