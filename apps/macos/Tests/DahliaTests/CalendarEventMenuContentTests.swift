import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CalendarEventMenuContentTests {
        @Test(arguments: [
            ("https://meet.google.com/abc", MeetingLinkService.googleMeet),
            ("https://us06web.zoom.us/j/123", .zoom),
            ("https://teams.microsoft.com/l/meetup-join/abc", .teams),
            ("https://app.slack.com/huddle/T1/C1", .slack),
        ])
        func joinTitleUsesMeetingService(conferenceURL: String, service: MeetingLinkService) throws {
            let url = try #require(URL(string: conferenceURL))

            #expect(CalendarEventMenuContent.joinTitle(for: url) == L10n.joinMeetingService(service.displayName))
        }

        @Test
        func joinTitleHandlesUnknownAndMissingLinks() throws {
            let unknownURL = try #require(URL(string: "https://example.com/meeting"))

            #expect(CalendarEventMenuContent.joinTitle(for: unknownURL) == L10n.join)
            #expect(CalendarEventMenuContent.joinTitle(for: nil) == nil)
        }
    }
#endif
