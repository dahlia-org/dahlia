import Foundation
import GRDB

enum RecordingAudioSource: String, Codable, DatabaseValueConvertible {
    case microphone
    case system

    var speakerLabel: String {
        switch self {
        case .microphone: "mic"
        case .system: "system"
        }
    }

    init?(speakerLabel: String?) {
        switch speakerLabel {
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
