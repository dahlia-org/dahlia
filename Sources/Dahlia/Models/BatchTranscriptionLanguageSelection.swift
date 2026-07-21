import Foundation

enum BatchTranscriptionLanguageSelection: Hashable, Sendable {
    case automatic
    case manual(localeIdentifier: String)

    var detectionMode: BatchLanguageDetectionMode {
        switch self {
        case .automatic:
            .automatic
        case .manual:
            .manual
        }
    }
}
