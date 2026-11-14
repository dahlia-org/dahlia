import Foundation
import Synchronization
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
        func databricksProxyJSONRPCErrorIsNotReadAsAnEmptyCalendarList() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ProxyNoGrantURLProtocol.self]
            let client = GoogleCalendarAPIClient(session: URLSession(configuration: configuration))
            func session(_ apiBaseURL: URL) -> GoogleSession {
                GoogleSession(
                    account: GoogleCalendarAccount(id: "1", displayName: "Test", email: ""),
                    accessToken: "token",
                    grantedScopes: GoogleOAuthScope.calendar,
                    apiBaseURL: apiBaseURL
                )
            }
            let proxy =
                try #require(
                    URL(string: "https://example.cloud.databricks.com/api/2.0/unity-catalog/connections/system_ai_agent_google_calendar/proxy/")
                )

            let error = await #expect(throws: GoogleCalendarAPIError.self) {
                try await client.fetchCalendarList(session: session(proxy))
            }

            #expect(error.map(DatabricksProxyGoogleSignInProvider.isNotAuthorized) == true)
            #expect(error?.errorDescription?.contains("Please login first") == true)

            let forbiddenConfiguration = URLSessionConfiguration.ephemeral
            forbiddenConfiguration.protocolClasses = [ProxyNoGrantForbiddenURLProtocol.self]
            let forbiddenClient = GoogleCalendarAPIClient(session: URLSession(configuration: forbiddenConfiguration))
            let rejected = await #expect(throws: GoogleCalendarAPIError.self) {
                try await forbiddenClient.fetchCalendarList(session: session(proxy))
            }
            #expect(rejected.map(DatabricksProxyGoogleSignInProvider.isNotAuthorized) == true)
            #expect(try await client.fetchCalendarList(session: session(GoogleCalendarAPIClient.googleAPIBaseURL)).isEmpty)
        }

        @Test
        func proxyGoogle401RequiresReauthenticationWithoutChangingOtherErrors() throws {
            let proxy = try #require(URL(string: "https://workspace.example/api/2.0/unity-catalog/connections/calendar/proxy/"))
            let google401 = Data(#"{"error":{"code":401,"message":"Invalid Credentials","status":"UNAUTHENTICATED"}}"#.utf8)
            let error = try #require(#expect(throws: GoogleCalendarAPIError.self) {
                try GoogleCalendarAPIClient.checkProxyError(in: google401, url: proxy, statusCode: 401)
            })
            guard case .proxyGoogleAuthenticationRequired = error else {
                Issue.record("Expected an actionable downstream authentication error")
                return
            }
            #expect(error.errorDescription == L10n.googleDatabricksReauthenticationRequired)
            #expect(!DatabricksProxyGoogleSignInProvider.isUnusableRoute(error))
            #expect(!DatabricksProxyGoogleSignInProvider.isNotAuthorized(error))
            try GoogleCalendarAPIClient.checkProxyError(in: google401, url: GoogleCalendarAPIClient.googleAPIBaseURL, statusCode: 401)
            try GoogleCalendarAPIClient.checkProxyError(in: google401, url: proxy, statusCode: 403)
            try GoogleCalendarAPIClient.checkProxyError(
                in: Data(#"{"error_code":"UNAUTHENTICATED","message":"Invalid Databricks token"}"#.utf8), url: proxy, statusCode: 401
            )
            try GoogleCalendarAPIClient.checkProxyError(in: Data("Unauthorized".utf8), url: proxy, statusCode: 401)
        }

        @Test
        func transientProxyGoogle401RetriesOnceAndLoadsCalendars() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GoogleInvalidCredentialURLProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let url = try #require(URL(string: "https://\(UUID().uuidString).example/transient/proxy/calendar/v3/users/me/calendarList"))
            defer { GoogleInvalidCredentialURLProtocol.requestCounts.withLock { $0[url] = nil } }

            let data = try await GoogleCalendarAPIClient.authorizedGet(url: url, accessToken: "test-token", session: transport)

            let response = try JSONDecoder().decode(GoogleCalendarAPIClient.CalendarListResponse.self, from: data)
            #expect(response.items.map(\.id) == ["primary"])
            #expect(GoogleInvalidCredentialURLProtocol.requestCounts.withLock { $0[url] } == 2)
        }

        @Test
        func calendarProxy401ShowsReauthenticationWhileDirect401StaysAnHTTPError() async throws {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GoogleInvalidCredentialURLProtocol.self]
            let transport = URLSession(configuration: configuration)
            defer { transport.invalidateAndCancel() }
            let client = GoogleCalendarAPIClient(session: transport)
            for proxy in [false, true] {
                let session = GoogleSession(
                    account: GoogleCalendarAccount(id: "1", displayName: "Test", email: ""),
                    accessToken: "test-token", grantedScopes: GoogleOAuthScope.calendar,
                    apiBaseURL: URL(string: proxy ? "https://workspace.example/api/2.0/unity-catalog/connections/calendar/proxy/" :
                        "https://www.googleapis.com/")!
                )
                let error = try #require(await #expect(throws: GoogleCalendarAPIError.self) {
                    try await client.fetchCalendarList(session: session)
                })
                switch error {
                case .proxyGoogleAuthenticationRequired: #expect(proxy)
                case .httpError(statusCode: 401, _): #expect(!proxy)
                default: Issue.record("Unexpected error: \(error)")
                }
                let count = GoogleInvalidCredentialURLProtocol.requestCounts.withLock { counts in
                    counts.filter { $0.key.host() == session.apiBaseURL.host() }.values.reduce(0, +)
                }
                #expect(count == (proxy ? 2 : 1))
            }
        }

        @Test
        func googleErrorBodySeparatesForwardedGoogleErrorsFromDatabricksRejections() {
            let missingConnection = GoogleCalendarAPIError.httpError(
                statusCode: 404,
                detail: #"{"error_code":"RESOURCE_DOES_NOT_EXIST","message":"Connection 'x' does not exist."}"#
            )
            let googleRateLimit = GoogleCalendarAPIError.httpError(
                statusCode: 403,
                detail: #"{"error":{"code":403,"message":"Rate Limit Exceeded","errors":[{"reason":"rateLimitExceeded"}]}}"#
            )

            #expect(!missingConnection.isGoogleError)
            #expect(googleRateLimit.isGoogleError)
            #expect(!GoogleCalendarAPIError.httpError(statusCode: 400, detail: "Unable to load OAuth Config").isGoogleError)
            for error in [missingConnection, .httpError(statusCode: 400, detail: "Unable to load OAuth Config")] {
                #expect(DatabricksProxyGoogleSignInProvider.isUnusableRoute(error))
            }
            #expect(!DatabricksProxyGoogleSignInProvider.isUnusableRoute(googleRateLimit))
            for statusCode in [408, 429] {
                #expect(!DatabricksProxyGoogleSignInProvider.isUnusableRoute(GoogleCalendarAPIError.httpError(statusCode: statusCode, detail: "")))
            }
            let googleRevokedGrant = GoogleCalendarAPIError.httpError(
                statusCode: 401,
                detail: #"{"error":{"code":401,"message":"Request had invalid authentication credentials."}}"#
            )
            #expect(!DatabricksProxyGoogleSignInProvider.isUnusableRoute(googleRevokedGrant))
        }

        @Test
        func fetchUpcomingEventsFiltersEventTypesAcrossPagesWithoutRepeatedQueryParameters() async throws {
            // Excluded types fill the first page, so the supported meeting arrives only on the next page.
            let firstPage = Data("""
            {
              "nextPageToken": "page-2",
              "items": [
                { "id": "ooo", "eventType": "outOfOffice",
                  "start": { "dateTime": "2026-04-17T02:00:00Z" }, "end": { "dateTime": "2026-04-17T03:00:00Z" } },
                { "id": "office", "eventType": "workingLocation",
                  "start": { "date": "2026-04-17" }, "end": { "date": "2026-04-18" } },
                { "id": "bday", "eventType": "birthday", "recurringEventId": "bday-series",
                  "start": { "date": "2026-04-17" }, "end": { "date": "2026-04-18" } },
                { "id": "untyped",
                  "start": { "dateTime": "2026-04-17T03:00:00Z" }, "end": { "dateTime": "2026-04-17T04:00:00Z" } }
              ]
            }
            """.utf8)
            let secondPage = Data("""
            {
              "items": [
                { "id": "meeting", "eventType": "default",
                  "start": { "dateTime": "2026-04-17T01:00:00Z" }, "end": { "dateTime": "2026-04-17T02:00:00Z" } }
              ]
            }
            """.utf8)
            let requestRecorder = RequestRecorderURLProtocol(responseBodiesByPageToken: ["": firstPage, "page-2": secondPage])
            let session = makeRecordingSession(recorder: requestRecorder)
            let client = GoogleCalendarAPIClient(session: session, calendar: Calendar(identifier: .gregorian))

            let events = try await client.fetchUpcomingEvents(
                session: GoogleSession(
                    account: GoogleCalendarAccount(id: "1", displayName: "Test", email: "test@example.com"),
                    accessToken: "token",
                    grantedScopes: GoogleOAuthScope.calendar
                ),
                calendars: [
                    CalendarListItem(
                        id: "primary",
                        title: "Primary",
                        colorHex: nil,
                        isPrimary: true
                    ),
                ],
                now: Date(timeIntervalSince1970: 1_776_384_000),
                daysAhead: 7
            )

            let queryItemsByRequest = try requestRecorder.requests.map { request in
                let url = try #require(request.url)
                return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            }
            #expect(queryItemsByRequest.map { $0.first { $0.name == "pageToken" }?.value } == [nil, "page-2"])
            // The Databricks connection proxy forwards only the last of repeated query parameters.
            #expect(queryItemsByRequest.allSatisfy { !$0.contains { $0.name == "eventTypes" } })
            #expect(events.map(\.platformId) == ["meeting", "ooo", "untyped"])
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
                calendarItem: CalendarListItem(
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
                calendarItem: CalendarListItem(id: "primary", title: "Primary", colorHex: nil, isPrimary: true)
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
                    {
                      "email": "colleague@example.com",
                      "displayName": "Colleague",
                      "optional": true,
                      "responseStatus": "accepted"
                    }
                  ]
                }
              ]
            }
            """.utf8)

            let response = try JSONDecoder().decode(GoogleCalendarAPIClient.EventListResponse.self, from: data)
            let item = try #require(response.items.first)
            let transformed = try GoogleCalendarAPIClient.makeEvent(
                from: item,
                calendarItem: CalendarListItem(id: "primary", title: "Primary", colorHex: nil, isPrimary: true)
            )
            let event = try #require(transformed)

            #expect(event.hasOtherAttendees)
            #expect(event.isDeclined)
            #expect(!event.isAttending)
            #expect(event.participants.count == 2)
            #expect(event.participants.first?.isCurrentUser == true)
            let colleague = try #require(event.participants.first { $0.email == "colleague@example.com" })
            #expect(colleague.displayName == "Colleague")
            #expect(colleague.kind == .person)
        }

        @Test
        func eventPayloadMarksAcceptedCurrentUserAsAttending() throws {
            let data = Data("""
            {
              "items": [
                {
                  "id": "accepted-meeting",
                  "start": { "dateTime": "2026-04-17T01:00:00Z" },
                  "end": { "dateTime": "2026-04-17T02:00:00Z" },
                  "attendees": [
                    { "email": "me@example.com", "self": true, "responseStatus": "accepted" },
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
                calendarItem: CalendarListItem(id: "primary", title: "Primary", colorHex: nil, isPrimary: true)
            )

            #expect(transformed?.isAttending == true)
        }

        @Test
        func eventPayloadExposesLocationAndRoomsMissingFromIt() throws {
            let data = Data("""
            {
              "items": [
                {
                  "id": "room-meeting",
                  "location": " Tokyo-15F-Shinjuku (6) [VC] ",
                  "start": { "dateTime": "2026-04-17T01:00:00Z" },
                  "end": { "dateTime": "2026-04-17T02:00:00Z" },
                  "attendees": [
                    { "email": "me@example.com", "self": true, "responseStatus": "accepted" },
                    { "email": "room1@resource.calendar.google.com", "displayName": "Tokyo-15F-Shinjuku (6) [VC]", "resource": true },
                    { "email": "room2@resource.calendar.google.com", "displayName": "Tokyo-15F-Ginza (4)", "resource": true },
                    { "displayName": "Tokyo-15F-Ginza (4)", "resource": true },
                    { "email": "room3@resource.calendar.google.com", "resource": true },
                    { "email": "colleague@example.com", "displayName": "Colleague" }
                  ]
                }
              ]
            }
            """.utf8)

            let response = try JSONDecoder().decode(GoogleCalendarAPIClient.EventListResponse.self, from: data)
            let item = try #require(response.items.first)
            let event = try #require(try GoogleCalendarAPIClient.makeEvent(
                from: item,
                calendarItem: CalendarListItem(id: "primary", title: "Primary", colorHex: nil, isPrimary: true)
            ))

            #expect(event.location == "Tokyo-15F-Shinjuku (6) [VC]")
            #expect(event.meetingRoomNames == ["Tokyo-15F-Ginza (4)"])
        }

        @Test(arguments: [
            ", \"organizer\": { \"self\": true }",
            "",
        ])
        func eventPayloadTreatsOrganizerOrMissingAttendeesAsAttending(_ participationJSON: String) throws {
            let data = Data("""
            {
              "items": [
                {
                  "id": "owned-meeting",
                  "start": { "dateTime": "2026-04-17T01:00:00Z" },
                  "end": { "dateTime": "2026-04-17T02:00:00Z" }
                  \(participationJSON)
                }
              ]
            }
            """.utf8)

            let response = try JSONDecoder().decode(GoogleCalendarAPIClient.EventListResponse.self, from: data)
            let item = try #require(response.items.first)
            let transformed = try GoogleCalendarAPIClient.makeEvent(
                from: item,
                calendarItem: CalendarListItem(id: "primary", title: "Primary", colorHex: nil, isPrimary: true)
            )

            #expect(transformed?.isAttending == true)
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
                calendarItem: CalendarListItem(id: "primary", title: "Primary", colorHex: nil, isPrimary: true)
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

        /// An Outlook invite has no conferenceData; its Teams link is only in the description.
        @Test
        func conferenceURIFallsBackToMeetingLinkInDescription() {
            let item = GoogleCalendarAPIClient.EventItem(
                id: "google-event-id",
                summary: "Customer sync",
                description: """
                Microsoft Teams meeting
                Join: <a href="https://teams.microsoft.com/meet/123?p=abc&amp;anon=true">https://teams.microsoft.com/meet/123?p=abc&amp;anon=true</a>
                Help: https://aka.ms/JoinTeamsMeeting
                """,
                location: "Microsoft Teams meeting",
                iCalUID: "outlook@example.com",
                htmlLink: nil,
                hangoutLink: nil,
                start: .init(date: nil, dateTime: "2026-11-12T06:00:00Z"),
                end: .init(date: nil, dateTime: "2026-11-12T07:00:00Z"),
                originalStartTime: nil,
                conferenceData: nil,
                eventType: nil
            )

            #expect(GoogleCalendarAPIClient.conferenceURI(for: item)?.absoluteString == "https://teams.microsoft.com/meet/123?p=abc&anon=true")
        }
    }

#endif

private final class RequestRecorderURLProtocol: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    private let responseBodiesByPageToken: [String: Data]

    init(responseBodiesByPageToken: [String: Data]) {
        self.responseBodiesByPageToken = responseBodiesByPageToken
    }

    var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    /// Records the request and returns the body for its `pageToken`, or for the first page when it has none.
    func record(_ request: URLRequest) -> Data {
        lock.withLock { storedRequests.append(request) }
        let pageToken = request.url
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?
            .first { $0.name == "pageToken" }?.value
        return responseBodiesByPageToken[pageToken ?? ""] ?? Data()
    }
}

private func makeRecordingSession(recorder: RequestRecorderURLProtocol) -> URLSession {
    RecordingURLProtocol.recorder = recorder

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecordingURLProtocol.self]
    return URLSession(configuration: configuration)
}

/// Replays the proxy's response for a user without a Google credential (captured 2026-11-06, identity redacted).
private class ProxyNoGrantURLProtocol: URLProtocol, @unchecked Sendable {
    class var statusCode: Int { 200 }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode, httpVersion: nil, headerFields: nil)!
        let body = #"{"jsonrpc":"2.0","error":{"code":-32600,"message":"{\"error_code\":\"UNAUTHENTICATED\",\"message\":\"Credential for user identity('1')"#
            + #" is not found for the connection 'system_ai_agent_google_calendar'."#
            + #" Please login first to the connection by visiting https://example.cloud.databricks.com/explore/connections/x\"}"}}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Observed as 200; another status must still read as a proxy error rather than a forwarded Google error.
private final class ProxyNoGrantForbiddenURLProtocol: ProxyNoGrantURLProtocol, @unchecked Sendable {
    override static var statusCode: Int { 403 }
}

private final class GoogleInvalidCredentialURLProtocol: URLProtocol, @unchecked Sendable {
    static let requestCounts = Mutex<[URL: Int]>([:])
    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #if canImport(Testing)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #endif
        let url = request.url!
        let count = Self.requestCounts.withLock { counts in
            counts[url, default: 0] += 1
            return counts[url]!
        }
        let recovered = url.path.contains("/transient/proxy/") && count > 1
        let response = HTTPURLResponse(url: url, statusCode: recovered ? 200 : 401, httpVersion: nil, headerFields: nil)!
        let body = recovered ? #"{"items":[{"id":"primary"}]}"# :
            #"{"error":{"code":401,"message":"Invalid Credentials","status":"UNAUTHENTICATED"}}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorder: RequestRecorderURLProtocol?

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = Self.recorder?.record(request) ?? Data()

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
