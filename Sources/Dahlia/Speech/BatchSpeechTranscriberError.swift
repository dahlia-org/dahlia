import Foundation

enum BatchSpeechTranscriberError: LocalizedError {
    case audioFormatUnavailable
    case invalidAudioRange
    case analysisDidNotAdvance
    case analysisStalled(minutes: Int)
    case languageModelPreparationFailed
    case noAutomaticLanguageCandidates
    case languageDetectionAudioLoadingFailed
    case languageDetectionFailed
    case unsupportedDetectedLanguage(String)

    var diagnosticCode: String {
        switch self {
        case .audioFormatUnavailable: "audioFormatUnavailable"
        case .invalidAudioRange: "invalidAudioRange"
        case .analysisDidNotAdvance: "analysisDidNotAdvance"
        case .analysisStalled: "analysisStalled"
        case .languageModelPreparationFailed: "languageModelPreparationFailed"
        case .noAutomaticLanguageCandidates: "noAutomaticLanguageCandidates"
        case .languageDetectionAudioLoadingFailed: "languageDetectionAudioLoadingFailed"
        case .languageDetectionFailed: "languageDetectionFailed"
        case .unsupportedDetectedLanguage: "unsupportedDetectedLanguage"
        }
    }

    var errorDescription: String? {
        switch self {
        case .audioFormatUnavailable:
            L10n.batchAudioFormatUnavailable
        case .invalidAudioRange:
            L10n.batchAudioRangeInvalid
        case .analysisDidNotAdvance:
            L10n.batchAnalysisDidNotAdvance
        case let .analysisStalled(minutes):
            L10n.batchAnalysisStalled(minutes: minutes)
        case .languageModelPreparationFailed:
            L10n.batchLanguageModelPreparationFailed
        case .noAutomaticLanguageCandidates:
            L10n.noAutomaticLanguageCandidates
        case .languageDetectionAudioLoadingFailed:
            L10n.batchLanguageDetectionAudioLoadingFailed
        case .languageDetectionFailed:
            L10n.batchLanguageDetectionFailed
        case let .unsupportedDetectedLanguage(languageIdentifier):
            L10n.batchDetectedLanguageUnsupported(languageIdentifier)
        }
    }
}
