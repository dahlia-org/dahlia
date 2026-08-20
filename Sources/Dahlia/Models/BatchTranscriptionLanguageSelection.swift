import Foundation

enum BatchTranscriptionLanguageSelection: Hashable, Sendable {
    case recorded
    case automatic
    case manual(localeIdentifier: String)

    var detectionMode: BatchLanguageDetectionMode {
        switch self {
        case .automatic:
            .automatic
        case .recorded, .manual:
            .manual
        }
    }
}
