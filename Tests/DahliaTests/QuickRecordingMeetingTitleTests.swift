import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct QuickRecordingMeetingTitleTests {
        @Test
        func titleIncludesLocalTimestamp() throws {
            let timeZone = try #require(TimeZone(secondsFromGMT: 9 * 60 * 60))

            let title = QuickRecordingMeetingTitle.make(
                at: Date(timeIntervalSince1970: 0),
                timeZone: timeZone
            )

            #expect(title == "Quick recording 1970-01-01 09:00:00")
        }
    }
#endif
