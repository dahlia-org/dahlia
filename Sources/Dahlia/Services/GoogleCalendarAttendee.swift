import Foundation

struct GoogleCalendarAttendee: Decodable {
    let isCurrentUser: Bool
    let responseStatus: String?

    private enum CodingKeys: String, CodingKey {
        case isCurrentUser = "self"
        case responseStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isCurrentUser = try container.decodeIfPresent(Bool.self, forKey: .isCurrentUser) ?? false
        responseStatus = try container.decodeIfPresent(String.self, forKey: .responseStatus)
    }
}
