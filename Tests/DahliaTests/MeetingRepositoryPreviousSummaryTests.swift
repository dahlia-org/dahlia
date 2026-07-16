import Foundation
@testable import Dahlia

// swiftformat:disable indent
#if canImport(Testing)
import Testing

@MainActor
struct MeetingRepositoryPreviousSummaryTests {
    @Test
    func fetchesLatestValidSummaryMetadataFromSameICalendarSeries() throws {
        let fixture = try PreviousSummaryTestFixture()
        let current = try fixture.insertMeeting(
            name: "Current",
            icalUid: "weekly@example.com",
            recurrenceId: "current",
            start: fixture.baseDate.addingTimeInterval(4 * 86_400)
        )
        _ = try fixture.insertMeeting(
            name: "Recent",
            icalUid: "weekly@example.com",
            recurrenceId: "recent",
            start: fixture.baseDate.addingTimeInterval(3 * 86_400),
            summary: SummaryDocument(title: "Recent", sections: [])
        )
        _ = try fixture.insertMeeting(
            name: "Corrupt",
            icalUid: "weekly@example.com",
            recurrenceId: "corrupt",
            start: fixture.baseDate.addingTimeInterval(2.5 * 86_400),
            invalidSummary: true
        )
        _ = try fixture.insertMeeting(
            name: "Older",
            icalUid: "weekly@example.com",
            recurrenceId: "older",
            start: fixture.baseDate.addingTimeInterval(2 * 86_400),
            summary: SummaryDocument(title: "Older", sections: [])
        )
        _ = try fixture.insertMeeting(
            name: "Oldest",
            icalUid: "weekly@example.com",
            recurrenceId: "oldest",
            start: fixture.baseDate.addingTimeInterval(86_400),
            summary: SummaryDocument(title: "Oldest", sections: [])
        )
        _ = try fixture.insertMeeting(
            name: "Other series",
            icalUid: "other@example.com",
            recurrenceId: "other",
            start: fixture.baseDate.addingTimeInterval(3.5 * 86_400),
            summary: SummaryDocument(title: "Other", sections: [])
        )
        _ = try fixture.insertMeeting(
            name: "Future",
            icalUid: "weekly@example.com",
            recurrenceId: "future",
            start: fixture.baseDate.addingTimeInterval(5 * 86_400),
            summary: SummaryDocument(title: "Future", sections: [])
        )

        let summaries = try fixture.repository.fetchPreviousMeetingMetadata(
            forMeetingId: current.id,
            limit: 2
        )

        #expect(summaries.map(\.name) == ["Recent", "Older"])
        #expect(summaries.allSatisfy { $0.calendarStart != nil && $0.calendarEnd != nil })
    }

    @Test
    func returnsNoPreviousSummariesWhenLimitIsZeroOrMeetingHasNoICalendarUID() throws {
        let fixture = try PreviousSummaryTestFixture()
        let unlinkedMeeting = try fixture.insertMeeting(
            name: "Unlinked",
            icalUid: nil,
            recurrenceId: nil,
            start: fixture.baseDate
        )

        #expect(try fixture.repository.fetchPreviousMeetingMetadata(
            forMeetingId: unlinkedMeeting.id,
            limit: 3
        ).isEmpty)
        #expect(try fixture.repository.fetchPreviousMeetingMetadata(
            forMeetingId: unlinkedMeeting.id,
            limit: 0
        ).isEmpty)
    }
}
#endif
// swiftformat:enable indent
