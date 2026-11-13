import Foundation

enum MeetingLinkService: String, CaseIterable, Identifiable, Sendable {
    case googleMeet
    case zoom
    case teams
    case slack

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .googleMeet: L10n.googleMeet
        case .zoom: L10n.zoom
        case .teams: L10n.microsoftTeams
        case .slack: L10n.slack
        }
    }

    init?(conferenceURL: URL) {
        guard let host = conferenceURL.host()?.lowercased() else { return nil }

        if Self.host(host, matches: "meet.google.com") {
            self = .googleMeet
        } else if Self.host(host, matches: "zoom.us") {
            self = .zoom
        } else if Self.host(host, matches: "teams.microsoft.com") {
            self = .teams
        } else if Self.host(host, matches: "slack.com") {
            self = .slack
        } else {
            return nil
        }
    }

    private static func host(_ host: String, matches domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }
}
