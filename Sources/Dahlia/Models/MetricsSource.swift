import GRDB

enum MetricsSource: String, CaseIterable, Codable, DatabaseValueConvertible, Sendable {
    case microphone = "mic"
    case system
    case unknown

    init(speakerLabel: String?) {
        switch speakerLabel {
        case "mic": self = .microphone
        case "system": self = .system
        default: self = .unknown
        }
    }
}
