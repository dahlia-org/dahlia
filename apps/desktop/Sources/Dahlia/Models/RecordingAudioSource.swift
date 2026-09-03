import Foundation
import GRDB

enum RecordingAudioSource: String, Codable, DatabaseValueConvertible, Sendable {
    case microphone
    case system

    var audioSource: String {
        switch self {
        case .microphone: "mic"
        case .system: "system"
        }
    }

    init?(audioSource: String?) {
        switch audioSource {
        case "mic":
            self = .microphone
        case "system":
            self = .system
        default:
            return nil
        }
    }

    var fileName: String { "\(rawValue).caf" }
}
