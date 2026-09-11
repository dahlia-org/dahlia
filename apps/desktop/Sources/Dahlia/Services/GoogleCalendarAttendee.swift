import Foundation

struct GoogleCalendarAttendee: Decodable {
    let email: String?
    let displayName: String?
    let isCurrentUser: Bool
    let isOrganizer: Bool
    let isOptional: Bool
    let isResource: Bool
    let responseStatus: String?

    private enum CodingKeys: String, CodingKey {
        case email
        case displayName
        case isCurrentUser = "self"
        case isOrganizer = "organizer"
        case isOptional = "optional"
        case isResource = "resource"
        case responseStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        isCurrentUser = try container.decodeIfPresent(Bool.self, forKey: .isCurrentUser) ?? false
        isOrganizer = try container.decodeIfPresent(Bool.self, forKey: .isOrganizer) ?? false
        isOptional = try container.decodeIfPresent(Bool.self, forKey: .isOptional) ?? false
        isResource = try container.decodeIfPresent(Bool.self, forKey: .isResource) ?? false
        responseStatus = try container.decodeIfPresent(String.self, forKey: .responseStatus)
    }

    func calendarParticipant() -> CalendarParticipant {
        CalendarParticipant(
            email: email,
            displayName: displayName,
            kind: isResource ? .resource : .person,
            isCurrentUser: isCurrentUser
        )
    }
}
