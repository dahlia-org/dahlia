import Foundation

enum MeetingLinkOpenTarget: Hashable, RawRepresentable, Sendable {
    case inheritGlobal
    case systemDefault
    case application(bundleIdentifier: String)

    private static let applicationPrefix = "application:"

    init?(rawValue: String) {
        switch rawValue {
        case "inherit":
            self = .inheritGlobal
        case "system":
            self = .systemDefault
        default:
            guard rawValue.hasPrefix(Self.applicationPrefix) else { return nil }
            let bundleIdentifier = String(rawValue.dropFirst(Self.applicationPrefix.count))
            guard !bundleIdentifier.isEmpty else { return nil }
            self = .application(bundleIdentifier: bundleIdentifier)
        }
    }

    var rawValue: String {
        switch self {
        case .inheritGlobal: "inherit"
        case .systemDefault: "system"
        case let .application(bundleIdentifier): "\(Self.applicationPrefix)\(bundleIdentifier)"
        }
    }
}
