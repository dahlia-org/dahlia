import DahliaRuntimeSupport
import Foundation

enum CalendarParticipantKind: String, Codable, CaseIterable, Sendable {
    case person
    case room
    case resource
    case group
    case unknown
}

struct CalendarParticipant: Codable, Equatable, Sendable {
    let email: String?
    let displayName: String?
    let kind: CalendarParticipantKind
    let isCurrentUser: Bool

    func mergingMissingMetadata(from fallback: Self) -> Self {
        Self(
            email: email ?? fallback.email,
            displayName: CalendarAttendeeNormalizer.displayName(displayName)
                ?? CalendarAttendeeNormalizer.displayName(fallback.displayName),
            kind: kind == .unknown ? fallback.kind : kind,
            isCurrentUser: isCurrentUser || fallback.isCurrentUser
        )
    }
}

struct CalendarAttendeeSnapshot: Codable, Equatable, Sendable {
    let email: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case email
        case displayName = "display_name"
    }
}

extension [CalendarParticipant] {
    var attendeeSnapshots: [CalendarAttendeeSnapshot] {
        var byEmail: [String: CalendarAttendeeSnapshot] = [:]
        for participant in self where participant.kind == .person && !participant.isCurrentUser {
            guard let rawEmail = participant.email,
                  let email = CalendarAttendeeNormalizer.email(rawEmail)
            else { continue }
            let displayName = CalendarAttendeeNormalizer.displayName(participant.displayName)
            if byEmail[email]?.displayName == nil || displayName != nil {
                byEmail[email] = CalendarAttendeeSnapshot(email: email, displayName: displayName)
            }
        }
        return byEmail.values.sorted { $0.email < $1.email }.prefix(1000).map(\.self)
    }
}
