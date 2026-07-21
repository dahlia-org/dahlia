import Foundation

enum BatchTranscriptionLanguageSelection: Hashable, Sendable {
    case automatic(fallbackLocaleIdentifier: String)
    case manual(localeIdentifier: String)

    var detectionMode: BatchLanguageDetectionMode {
        switch self {
        case .automatic:
            .automatic
        case .manual:
            .manual
        }
    }

    var localeIdentifier: String {
        switch self {
        case let .automatic(fallbackLocaleIdentifier):
            fallbackLocaleIdentifier
        case let .manual(localeIdentifier):
            localeIdentifier
        }
    }
}
