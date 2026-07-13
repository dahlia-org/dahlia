import Foundation

enum CalendarEventPlatform {
    static let googleCalendar = "GoogleCalendar"
    static let macOSCalendar = "MacOSCalendar"
}

struct CalendarEvent: Identifiable, Equatable, Codable {
    let id: String
    let calendarID: String
    let calendarName: String
    let calendarColorHex: String?
    let platform: String
    let platformId: String
    let title: String
    let description: String
    let icalUid: String?
    let recurrenceId: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let hasOtherAttendees: Bool
    let isDeclined: Bool
    let isOutOfOffice: Bool
    let conferenceURI: URL?
    let url: URL?

    init(
        id: String,
        calendarID: String,
        calendarName: String,
        calendarColorHex: String?,
        platform: String = CalendarEventPlatform.googleCalendar,
        platformId: String,
        title: String,
        description: String,
        icalUid: String?,
        recurrenceId: String = ICalendarRecurrenceID.singleEvent,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        hasOtherAttendees: Bool = false,
        isDeclined: Bool = false,
        isOutOfOffice: Bool = false,
        conferenceURI: URL?,
        url: URL? = nil
    ) {
        self.id = id
        self.calendarID = calendarID
        self.calendarName = calendarName
        self.calendarColorHex = calendarColorHex
        self.platform = platform
        self.platformId = platformId
        self.title = title
        self.description = description
        self.icalUid = icalUid
        self.recurrenceId = recurrenceId
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.hasOtherAttendees = hasOtherAttendees
        self.isDeclined = isDeclined
        self.isOutOfOffice = isOutOfOffice || Self.titleIndicatesOutOfOffice(title)
        self.conferenceURI = conferenceURI
        self.url = url
    }
}

extension CalendarEvent {
    var key: CalendarEventKey? {
        CalendarEventKey(icalUid: icalUid, recurrenceId: recurrenceId)
    }

    var resolvedMeetingTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? L10n.newMeeting : trimmedTitle
    }

    static func titleIndicatesOutOfOffice(_ title: String) -> Bool {
        title
            .uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .contains { $0 == "OOO" || $0 == "OOTO" }
    }
}

extension [CalendarEvent] {
    /// Google と macOS の両ソースが同じ物理イベントを返した場合に 1 件へ畳み込む。
    /// iCalendar の UID と RECURRENCE-ID で照合し、会議 URI などの情報が揃っている
    /// Google 側を優先する。同一ソース内の重複
    /// （複数カレンダーに同じ予定がある場合）は従来どおり残す。
    func deduplicatedAcrossSources() -> [CalendarEvent] {
        var indexByKey: [CalendarEventKey: Int] = [:]
        var result: [CalendarEvent] = []

        for event in self {
            guard let key = event.key else {
                result.append(event)
                continue
            }

            guard let existingIndex = indexByKey[key] else {
                indexByKey[key] = result.count
                result.append(event)
                continue
            }

            let existing = result[existingIndex]
            if existing.platform == event.platform {
                result.append(event)
            } else {
                let preferred = event.platform == CalendarEventPlatform.googleCalendar ? event : existing
                let fallback = event.platform == CalendarEventPlatform.googleCalendar ? existing : event
                result[existingIndex] = preferred.mergingMissingMetadata(from: fallback)
            }
        }
        return result
    }
}

private extension CalendarEvent {
    func mergingMissingMetadata(from fallback: CalendarEvent) -> CalendarEvent {
        CalendarEvent(
            id: id,
            calendarID: calendarID,
            calendarName: calendarName,
            calendarColorHex: calendarColorHex,
            platform: platform,
            platformId: platformId,
            title: title,
            description: description.nilIfBlank ?? fallback.description,
            icalUid: icalUid,
            recurrenceId: recurrenceId,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            hasOtherAttendees: hasOtherAttendees || fallback.hasOtherAttendees,
            isDeclined: isDeclined || fallback.isDeclined,
            isOutOfOffice: isOutOfOffice || fallback.isOutOfOffice,
            conferenceURI: conferenceURI ?? fallback.conferenceURI,
            url: url ?? fallback.url
        )
    }
}

extension CalendarEvent {
    private enum CodingKeys: String, CodingKey {
        case id
        case calendarID
        case calendarName
        case calendarColorHex
        case platform
        case platformId
        case title
        case description
        case icalUid
        case recurrenceId
        case startDate
        case endDate
        case isAllDay
        case hasOtherAttendees
        case isDeclined
        case isOutOfOffice
        case conferenceURI
        case url
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case meetingURL
        case sourceEventURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        calendarID = try container.decode(String.self, forKey: .calendarID)
        calendarName = try container.decode(String.self, forKey: .calendarName)
        calendarColorHex = try container.decodeIfPresent(String.self, forKey: .calendarColorHex)
        platform = try container.decode(String.self, forKey: .platform)
        platformId = try container.decode(String.self, forKey: .platformId)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decode(String.self, forKey: .description)
        icalUid = try container.decodeIfPresent(String.self, forKey: .icalUid)
        recurrenceId = try container.decodeIfPresent(String.self, forKey: .recurrenceId) ?? ICalendarRecurrenceID.singleEvent
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decode(Date.self, forKey: .endDate)
        isAllDay = try container.decode(Bool.self, forKey: .isAllDay)
        hasOtherAttendees = try container.decodeIfPresent(Bool.self, forKey: .hasOtherAttendees) ?? false
        isDeclined = try container.decodeIfPresent(Bool.self, forKey: .isDeclined) ?? false
        let decodedIsOutOfOffice = try container.decodeIfPresent(Bool.self, forKey: .isOutOfOffice) ?? false
        isOutOfOffice = decodedIsOutOfOffice || Self.titleIndicatesOutOfOffice(title)
        conferenceURI = try container.decodeIfPresent(URL.self, forKey: .conferenceURI)
            ?? legacyContainer.decodeIfPresent(URL.self, forKey: .meetingURL)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
            ?? legacyContainer.decodeIfPresent(URL.self, forKey: .sourceEventURL)
    }
}
