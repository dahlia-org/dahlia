import Foundation

enum GoogleCalendarAPIError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, detail: String)
    case invalidCalendarDate(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            L10n.googleCalendarUnexpectedResponse
        case let .httpError(statusCode, detail):
            L10n.googleCalendarHTTPError(statusCode, detail)
        case let .invalidCalendarDate(value):
            L10n.googleCalendarInvalidDate(value)
        }
    }
}

@MainActor
protocol GoogleCalendarAPIClientProviding: AnyObject {
    func fetchCalendarList(accessToken: String) async throws -> [CalendarListItem]
    func fetchUpcomingEvents(
        accessToken: String,
        calendars: [CalendarListItem],
        now: Date,
        daysAhead: Int
    ) async throws -> [CalendarEvent]
}

@MainActor
final class GoogleCalendarAPIClient: GoogleCalendarAPIClientProviding {
    private let session: URLSession
    private let calendar: Calendar

    init(session: URLSession = .shared, calendar: Calendar = .current) {
        self.session = session
        self.calendar = calendar
    }

    func fetchCalendarList(accessToken: String) async throws -> [CalendarListItem] {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")
        components?.queryItems = [
            URLQueryItem(name: "minAccessRole", value: "reader"),
            URLQueryItem(name: "showDeleted", value: "false"),
        ]

        let data = try await request(url: Self.url(from: components), accessToken: accessToken)
        let response = try JSONDecoder().decode(CalendarListResponse.self, from: data)
        return response.items
            .filter { !$0.deleted }
            .map {
                CalendarListItem(
                    id: $0.id,
                    title: $0.summaryOverride?.nilIfBlank ?? $0.summary?.nilIfBlank ?? $0.id,
                    colorHex: $0.backgroundColor,
                    isPrimary: $0.primary
                )
            }
            .sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary {
                    return lhs.isPrimary && !rhs.isPrimary
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    func fetchUpcomingEvents(
        accessToken: String,
        calendars: [CalendarListItem],
        now: Date,
        daysAhead: Int = 7
    ) async throws -> [CalendarEvent] {
        let intervalEnd = calendar.date(byAdding: .day, value: daysAhead, to: now) ?? now
        let calendarRef = calendar

        let fetchResults = try await withThrowingTaskGroup(
            of: (CalendarListItem, Data).self,
            returning: [(CalendarListItem, Data)].self
        ) { group in
            for calendarItem in calendars {
                group.addTask {
                    let data = try await Self.requestEvents(
                        for: calendarItem,
                        accessToken: accessToken,
                        now: now,
                        intervalEnd: intervalEnd,
                        session: self.session
                    )
                    return (calendarItem, data)
                }
            }

            var results: [(CalendarListItem, Data)] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        var events: [CalendarEvent] = []
        for (calendarItem, data) in fetchResults {
            let response = try JSONDecoder().decode(EventListResponse.self, from: data)
            let calendarEvents = try response.items.compactMap {
                try Self.makeEvent(from: $0, calendarItem: calendarItem, calendar: calendarRef)
            }
            events.append(contentsOf: calendarEvents)
        }

        return Self.sortAndFilter(events, now: now, intervalEnd: intervalEnd)
    }

    static func makeEvent(
        from item: EventItem,
        calendarItem: CalendarListItem,
        calendar: Calendar = .current
    ) throws -> CalendarEvent? {
        guard let start = try item.start.resolvedDate(calendar: calendar),
              let end = try item.end.resolvedDate(calendar: calendar)
        else { return nil }
        let recurrenceId: String
        if let originalStartTime = item.originalStartTime {
            guard let resolvedRecurrenceId = try originalStartTime.resolvedRecurrenceId(calendar: calendar) else {
                throw GoogleCalendarAPIError.invalidResponse
            }
            recurrenceId = resolvedRecurrenceId
        } else {
            guard item.recurringEventId?.nilIfBlank == nil else {
                throw GoogleCalendarAPIError.invalidResponse
            }
            recurrenceId = ICalendarRecurrenceID.singleEvent
        }

        return CalendarEvent(
            id: "\(calendarItem.id)::\(item.id)",
            calendarID: calendarItem.id,
            calendarName: calendarItem.title,
            calendarColorHex: calendarItem.colorHex,
            platform: CalendarEventPlatform.googleCalendar,
            platformId: item.id,
            title: item.summary?.nilIfBlank ?? L10n.googleCalendarUntitledEvent,
            description: item.description?.nilIfBlank ?? "",
            icalUid: item.iCalUID?.nilIfBlank,
            recurrenceId: recurrenceId,
            startDate: start,
            endDate: max(end, start),
            isAllDay: item.start.date != nil,
            hasOtherAttendees: item.hasOtherAttendees,
            isDeclined: item.isDeclinedByCurrentUser,
            isAttending: item.isAcceptedByCurrentUser,
            isOutOfOffice: item.eventType == "outOfOffice",
            conferenceURI: conferenceURI(for: item),
            url: absoluteURL(from: item.htmlLink)
        )
    }

    static func conferenceURI(for item: EventItem) -> URL? {
        let entryPoints = item.conferenceData?.entryPoints.compactMap { entryPoint -> (type: String?, uri: URL)? in
            guard let uri = absoluteURL(from: entryPoint.uri) else { return nil }
            return (entryPoint.entryPointType?.lowercased(), uri)
        } ?? []
        let entryPointURIs = entryPoints.map(\.uri)
        let videoURIs = entryPoints.filter { $0.type == "video" }.map(\.uri)
        let hangoutURI = absoluteURL(from: item.hangoutLink)
        let httpsHangoutURI = hangoutURI.flatMap { $0.isHTTPS ? $0 : nil }

        return videoURIs.first(where: \.isHTTPS)
            ?? httpsHangoutURI
            ?? entryPointURIs.first(where: \.isHTTPS)
            ?? videoURIs.first
            ?? hangoutURI
            ?? entryPointURIs.first
    }

    static func sortAndFilter(
        _ events: [CalendarEvent],
        now: Date,
        intervalEnd: Date
    ) -> [CalendarEvent] {
        events
            .filter { $0.endDate >= now && $0.startDate <= intervalEnd }
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                if lhs.isAllDay != rhs.isAllDay {
                    return lhs.isAllDay && !rhs.isAllDay
                }
                let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
                if titleComparison != .orderedSame {
                    return titleComparison == .orderedAscending
                }
                return lhs.id < rhs.id
            }
    }

    private static func requestEvents(
        for calendarItem: CalendarListItem,
        accessToken: String,
        now: Date,
        intervalEnd: Date,
        session: URLSession
    ) async throws -> Data {
        guard let encodedCalendarID = calendarItem.id.addingPercentEncoding(withAllowedCharacters: .calendarAPIPathComponentAllowed),
              let components = URLComponents(
                  string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedCalendarID)/events"
              )
        else {
            throw GoogleCalendarAPIError.invalidResponse
        }

        var queryComponents = components
        queryComponents.queryItems = [
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "showDeleted", value: "false"),
            URLQueryItem(name: "timeMin", value: now.ISO8601Format()),
            URLQueryItem(name: "timeMax", value: intervalEnd.ISO8601Format()),
            URLQueryItem(name: "maxResults", value: "250"),
        ] + Self.includedEventTypesForUpcomingEvents.map { eventType in
            URLQueryItem(name: "eventTypes", value: eventType)
        }

        let url = try Self.url(from: queryComponents)
        return try await authorizedGet(url: url, accessToken: accessToken, session: session)
    }

    private func request(url: URL, accessToken: String) async throws -> Data {
        try await Self.authorizedGet(url: url, accessToken: accessToken, session: session)
    }

    private static func authorizedGet(url: URL, accessToken: String, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleCalendarAPIError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw GoogleCalendarAPIError.httpError(statusCode: httpResponse.statusCode, detail: detail)
        }
        return data
    }

    private static func url(from components: URLComponents?) throws -> URL {
        guard let url = components?.url else {
            throw GoogleCalendarAPIError.invalidResponse
        }
        return url
    }

    private static func absoluteURL(from value: String?) -> URL? {
        guard let value = value?.nilIfBlank,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased().nilIfBlank,
              !(["http", "https"].contains(scheme) && url.host?.nilIfBlank == nil)
        else { return nil }
        return url
    }
}

extension GoogleCalendarAPIClient {
    private static let includedEventTypesForUpcomingEvents = [
        "default",
        "focusTime",
        "fromGmail",
        "outOfOffice",
    ]

    struct CalendarListResponse: Decodable {
        let items: [CalendarListItemPayload]

        private enum CodingKeys: String, CodingKey {
            case items
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            items = try container.decodeIfPresent([CalendarListItemPayload].self, forKey: .items) ?? []
        }
    }

    struct CalendarListItemPayload: Decodable {
        let id: String
        let summary: String?
        let summaryOverride: String?
        let backgroundColor: String?
        let primary: Bool
        let deleted: Bool

        private enum CodingKeys: String, CodingKey {
            case id
            case summary
            case summaryOverride
            case backgroundColor
            case primary
            case deleted
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
            summaryOverride = try container.decodeIfPresent(String.self, forKey: .summaryOverride)
            backgroundColor = try container.decodeIfPresent(String.self, forKey: .backgroundColor)
            primary = try container.decodeIfPresent(Bool.self, forKey: .primary) ?? false
            deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        }
    }

    struct EventListResponse: Decodable {
        let items: [EventItem]
    }

    struct EventItem: Decodable {
        struct EventDateTime: Decodable {
            let date: String?
            let dateTime: String?
            let timeZone: String?

            init(date: String?, dateTime: String?, timeZone: String? = nil) {
                self.date = date
                self.dateTime = dateTime
                self.timeZone = timeZone
            }

            func resolvedDate(calendar: Calendar) throws -> Date? {
                if let dateTime {
                    if let parsed = Self.googleCalendarWithFractionalSeconds.date(from: dateTime) {
                        return parsed
                    }
                    if let parsed = Self.googleCalendar.date(from: dateTime) {
                        return parsed
                    }
                    return localDate(from: dateTime)
                }

                if let date {
                    return try calendar.googleCalendarDate(from: date)
                }

                return nil
            }

            func resolvedRecurrenceId(calendar: Calendar) throws -> String? {
                if let date {
                    _ = try calendar.googleCalendarDate(from: date)
                    guard let recurrenceId = ICalendarRecurrenceID.date(date) else {
                        throw GoogleCalendarAPIError.invalidCalendarDate(date)
                    }
                    return recurrenceId
                }

                guard let resolvedDate = try resolvedDate(calendar: calendar) else {
                    throw GoogleCalendarAPIError.invalidCalendarDate(dateTime ?? "")
                }
                return ICalendarRecurrenceID.dateTime(resolvedDate)
            }

            private func localDate(from value: String) -> Date? {
                guard let timeZone = timeZone.flatMap(TimeZone.init(identifier:)) else { return nil }
                for includesFractionalSeconds in [true, false] {
                    let formatter = ISO8601DateFormatter()
                    formatter.timeZone = timeZone
                    formatter.formatOptions = includesFractionalSeconds
                        ? [.withFullDate, .withTime, .withColonSeparatorInTime, .withFractionalSeconds]
                        : [.withFullDate, .withTime, .withColonSeparatorInTime]
                    if let date = formatter.date(from: value) {
                        return date
                    }
                }
                return nil
            }

            private nonisolated(unsafe) static let googleCalendarWithFractionalSeconds: ISO8601DateFormatter = {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter
            }()

            private nonisolated(unsafe) static let googleCalendar: ISO8601DateFormatter = {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                return formatter
            }()
        }

        struct ConferenceData: Decodable {
            struct EntryPoint: Decodable {
                let uri: String?
                let entryPointType: String?

                init(uri: String?, entryPointType: String? = nil) {
                    self.uri = uri
                    self.entryPointType = entryPointType
                }
            }

            let entryPoints: [EntryPoint]
        }

        let id: String
        let summary: String?
        let description: String?
        let iCalUID: String?
        let htmlLink: String?
        let hangoutLink: String?
        let start: EventDateTime
        let end: EventDateTime
        let originalStartTime: EventDateTime?
        let recurringEventId: String?
        let conferenceData: ConferenceData?
        let eventType: String?
        let attendees: [GoogleCalendarAttendee]?

        init(
            id: String,
            summary: String?,
            description: String?,
            iCalUID: String?,
            htmlLink: String?,
            hangoutLink: String?,
            start: EventDateTime,
            end: EventDateTime,
            originalStartTime: EventDateTime?,
            recurringEventId: String? = nil,
            conferenceData: ConferenceData?,
            eventType: String?,
            attendees: [GoogleCalendarAttendee]? = nil
        ) {
            self.id = id
            self.summary = summary
            self.description = description
            self.iCalUID = iCalUID
            self.htmlLink = htmlLink
            self.hangoutLink = hangoutLink
            self.start = start
            self.end = end
            self.originalStartTime = originalStartTime
            self.recurringEventId = recurringEventId
            self.conferenceData = conferenceData
            self.eventType = eventType
            self.attendees = attendees
        }

        var hasOtherAttendees: Bool {
            attendees?.contains { !$0.isCurrentUser } == true
        }

        var isDeclinedByCurrentUser: Bool {
            attendees?.first(where: \.isCurrentUser)?.responseStatus == "declined"
        }

        var isAcceptedByCurrentUser: Bool {
            attendees?.first(where: \.isCurrentUser)?.responseStatus == "accepted"
        }
    }
}

private extension URL {
    var isHTTPS: Bool {
        scheme?.lowercased() == "https"
    }
}

private extension Calendar {
    func googleCalendarDate(from value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = self
        formatter.timeZone = timeZone
        guard let date = formatter.date(from: value) else {
            throw GoogleCalendarAPIError.invalidCalendarDate(value)
        }
        return date
    }
}

private extension CharacterSet {
    static let calendarAPIPathComponentAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
}
