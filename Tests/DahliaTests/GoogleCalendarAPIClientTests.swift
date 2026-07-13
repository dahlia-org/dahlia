import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

@MainActor
struct GoogleCalendarAPIClientTests {
    @Test
    func calendarListDecodingAllowsMissingOptionalFields() throws {
        let data = Data("""
        {
          "items": [
            {
              "id": "primary"
            }
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(GoogleCalendarAPIClient.CalendarListResponse.self, from: data)

        #expect(response.items.count == 1)
        #expect(response.items[0].id == "primary")
        #expect(response.items[0].summary == nil)
        #expect(response.items[0].primary == false)
        #expect(response.items[0].deleted == false)
    }

    @Test
    func calendarListDecodingAllowsMissingItemsArray() throws {
        let data = Data("{}".utf8)

        let response = try JSONDecoder().decode(GoogleCalendarAPIClient.CalendarListResponse.self, from: data)

        #expect(response.items.isEmpty)
    }

    @Test
    func fetchUpcomingEventsRequestsOnlySupportedEventTypes() async throws {
        let requestRecorder = RequestRecorderURLProtocol()
        let session = makeRecordingSession(recorder: requestRecorder)
        let client = GoogleCalendarAPIClient(session: session, calendar: Calendar(identifier: .gregorian))

        _ = try await client.fetchUpcomingEvents(
            accessToken: "token",
            calendars: [
                GoogleCalendarListItem(
                    id: "primary",
                    title: "Primary",
                    colorHex: nil,
                    isPrimary: true
                ),
            ],
            now: Date(timeIntervalSince1970: 1_776_384_000),
            daysAhead: 7
        )

        let request = try #require(requestRecorder.lastRequest)
        let url = try #require(request.url)
        let queryItems = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let eventTypes = queryItems
            .filter { $0.name == "eventTypes" }
            .compactMap(\.value)

        #expect(Set(eventTypes) == Set(["default", "focusTime", "fromGmail", "outOfOffice"]))
    }

    @Test
    func makeEventIncludesPersistenceFields() throws {
        let item = GoogleCalendarAPIClient.EventItem(
            id: "google-event-id",
            summary: "Planning",
            description: "Quarterly planning",
            iCalUID: "planning@google.com",
            htmlLink: "https://calendar.google.com/calendar/event?eid=planning",
            hangoutLink: "https://meet.google.com/test-room",
            start: .init(date: nil, dateTime: "2026-04-17T01:00:00Z"),
            end: .init(date: nil, dateTime: "2026-04-17T02:00:00Z"),
            originalStartTime: .init(date: nil, dateTime: "2026-04-17T00:30:00Z"),
            recurringEventId: "series-id",
            conferenceData: nil,
            eventType: nil
        )

        let transformedEvent = try GoogleCalendarAPIClient.makeEvent(
            from: item,
            calendarItem: GoogleCalendarListItem(
                id: "primary",
                title: "Primary",
                colorHex: "#4285F4",
                isPrimary: true
            ),
            calendar: Calendar(identifier: .gregorian)
        )
        let event = try #require(transformedEvent)

        #expect(event.platformId == "google-event-id")
        #expect(event.description == "Quarterly planning")
        #expect(event.icalUid == "planning@google.com")
        #expect(event.recurrenceId == "20260417T003000Z")
        #expect(event.conferenceURI?.absoluteString == "https://meet.google.com/test-room")
        #expect(event.url?.absoluteString == "https://calendar.google.com/calendar/event?eid=planning")
        #expect(event.startDate == Date(timeIntervalSince1970: 1_776_387_600))
        #expect(event.endDate == Date(timeIntervalSince1970: 1_776_391_200))
    }

    @Test
    func eventPayloadDecodesOriginalStartTimeAndEventURL() throws {
        let data = Data("""
        {
          "items": [
            {
              "id": "recurring-instance",
              "iCalUID": "series@google.com",
              "htmlLink": "https://calendar.google.com/calendar/event?eid=instance",
              "start": { "dateTime": "2026-04-17T01:00:00Z" },
              "end": { "dateTime": "2026-04-17T02:00:00Z" },
              "originalStartTime": { "dateTime": "2026-04-17T00:30:00Z" }
            }
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(GoogleCalendarAPIClient.EventListResponse.self, from: data)
        let item = try #require(response.items.first)
        let transformed = try GoogleCalendarAPIClient.makeEvent(
            from: item,
            calendarItem: GoogleCalendarListItem(id: "primary", title: "Primary", colorHex: nil, isPrimary: true)
        )
        let event = try #require(transformed)

        #expect(event.recurrenceId == "20260417T003000Z")
        #expect(event.url?.absoluteString == "https://calendar.google.com/calendar/event?eid=instance")
    }

    @Test
    func eventPayloadIncludesAttendeeAndDeclineMetadata() throws {
        let data = Data("""
        {
          "items": [
            {
              "id": "declined-meeting",
              "start": { "dateTime": "2026-04-17T01:00:00Z" },
              "end": { "dateTime": "2026-04-17T02:00:00Z" },
              "attendees": [
                { "email": "me@example.com", "self": true, "responseStatus": "declined" },
                { "email": "colleague@example.com", "responseStatus": "accepted" }
              ]
            }
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(GoogleCalendarAPIClient.EventListResponse.self, from: data)
        let item = try #require(response.items.first)
        let transformed = try GoogleCalendarAPIClient.makeEvent(
            from: item,
            calendarItem: GoogleCalendarListItem(id: "primary", title: "Primary", colorHex: nil, isPrimary: true)
        )
        let event = try #require(transformed)

        #expect(event.hasOtherAttendees)
        #expect(event.isDeclined)
    }

    @Test
    func originalStartTimeUsesItsIANATimeZoneWhenOffsetIsOmitted() throws {
        let data = Data("""
        {
          "items": [
            {
              "id": "recurring-instance",
              "recurringEventId": "series-id",
              "iCalUID": "series@google.com",
              "start": { "dateTime": "2026-04-17T01:00:00-07:00" },
              "end": { "dateTime": "2026-04-17T02:00:00-07:00" },
              "originalStartTime": {
                "dateTime": "2026-04-17T00:30:00",
                "timeZone": "America/Los_Angeles"
              }
            }
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(GoogleCalendarAPIClient.EventListResponse.self, from: data)
        let item = try #require(response.items.first)
        let transformed = try GoogleCalendarAPIClient.makeEvent(
            from: item,
            calendarItem: GoogleCalendarListItem(id: "primary", title: "Primary", colorHex: nil, isPrimary: true)
        )

        #expect(transformed?.recurrenceId == "20260417T073000Z")
    }

    @Test
    func conferenceURIKeepsHTTPSHangoutAheadOfPhoneEntryPoint() {
        let item = GoogleCalendarAPIClient.EventItem(
            id: "google-event-id",
            summary: "Planning",
            description: nil,
            iCalUID: "planning@google.com",
            htmlLink: nil,
            hangoutLink: "https://meet.google.com/test-room",
            start: .init(date: nil, dateTime: "2026-04-17T01:00:00Z"),
            end: .init(date: nil, dateTime: "2026-04-17T02:00:00Z"),
            originalStartTime: nil,
            conferenceData: .init(entryPoints: [
                .init(uri: "tel:+1-555-0100", entryPointType: "phone"),
            ]),
            eventType: nil
        )

        #expect(GoogleCalendarAPIClient.conferenceURI(for: item)?.absoluteString == item.hangoutLink)
    }
}

#elseif canImport(XCTest)
import XCTest

@MainActor
final class GoogleCalendarAPIClientTests: XCTestCase {
    func testCalendarListDecodingAllowsMissingOptionalFields() throws {
        let data = Data("""
        {
          "items": [
            {
              "id": "primary"
            }
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(GoogleCalendarAPIClient.CalendarListResponse.self, from: data)

        XCTAssertEqual(response.items.count, 1)
        XCTAssertEqual(response.items[0].id, "primary")
        XCTAssertNil(response.items[0].summary)
        XCTAssertFalse(response.items[0].primary)
        XCTAssertFalse(response.items[0].deleted)
    }

    func testCalendarListDecodingAllowsMissingItemsArray() throws {
        let data = Data("{}".utf8)

        let response = try JSONDecoder().decode(GoogleCalendarAPIClient.CalendarListResponse.self, from: data)

        XCTAssertTrue(response.items.isEmpty)
    }

    func testFetchUpcomingEventsRequestsOnlySupportedEventTypes() async throws {
        let requestRecorder = RequestRecorderURLProtocol()
        let session = makeRecordingSession(recorder: requestRecorder)
        let client = GoogleCalendarAPIClient(session: session, calendar: Calendar(identifier: .gregorian))

        _ = try await client.fetchUpcomingEvents(
            accessToken: "token",
            calendars: [
                GoogleCalendarListItem(
                    id: "primary",
                    title: "Primary",
                    colorHex: nil,
                    isPrimary: true
                ),
            ],
            now: Date(timeIntervalSince1970: 1_776_384_000),
            daysAhead: 7
        )

        let request = try XCTUnwrap(requestRecorder.lastRequest)
        let url = try XCTUnwrap(request.url)
        let queryItems = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let eventTypes = queryItems
            .filter { $0.name == "eventTypes" }
            .compactMap(\.value)

        XCTAssertEqual(Set(eventTypes), Set(["default", "focusTime", "fromGmail", "outOfOffice"]))
    }

    func testMakeEventIncludesPersistenceFields() throws {
        let item = GoogleCalendarAPIClient.EventItem(
            id: "google-event-id",
            summary: "Planning",
            description: "Quarterly planning",
            iCalUID: "planning@google.com",
            htmlLink: "https://calendar.google.com/calendar/event?eid=planning",
            hangoutLink: "https://meet.google.com/test-room",
            start: .init(date: nil, dateTime: "2026-04-17T01:00:00Z"),
            end: .init(date: nil, dateTime: "2026-04-17T02:00:00Z"),
            originalStartTime: .init(date: nil, dateTime: "2026-04-17T00:30:00Z"),
            recurringEventId: "series-id",
            conferenceData: nil,
            eventType: nil
        )

        let event = try XCTUnwrap(
            GoogleCalendarAPIClient.makeEvent(
                from: item,
                calendarItem: GoogleCalendarListItem(
                    id: "primary",
                    title: "Primary",
                    colorHex: "#4285F4",
                    isPrimary: true
                ),
                calendar: Calendar(identifier: .gregorian)
            )
        )

        XCTAssertEqual(event.platformId, "google-event-id")
        XCTAssertEqual(event.description, "Quarterly planning")
        XCTAssertEqual(event.icalUid, "planning@google.com")
        XCTAssertEqual(event.recurrenceId, "20260417T003000Z")
        XCTAssertEqual(event.conferenceURI?.absoluteString, "https://meet.google.com/test-room")
        XCTAssertEqual(event.url?.absoluteString, "https://calendar.google.com/calendar/event?eid=planning")
        XCTAssertEqual(event.startDate, Date(timeIntervalSince1970: 1_776_387_600))
        XCTAssertEqual(event.endDate, Date(timeIntervalSince1970: 1_776_391_200))
    }
}
#endif

private final class RequestRecorderURLProtocol: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var lastRequest: URLRequest? {
        lock.withLock { storedRequest }
    }

    func record(_ request: URLRequest) {
        lock.withLock {
            storedRequest = request
        }
    }
}

private func makeRecordingSession(recorder: RequestRecorderURLProtocol) -> URLSession {
    RecordingURLProtocol.recorder = recorder

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecordingURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorder: RequestRecorderURLProtocol?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recorder?.record(request)

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = Data(#"{"items":[]}"#.utf8)

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
