import Foundation
@testable import Dahlia

// swiftformat:disable indent
#if canImport(Testing)
import Testing

@MainActor
struct SummaryPromptContextTests {
    @Test
    func xmlUsesStructuredEscapedMeetingData() throws {
        let meetingId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E6"))
        let context = SummaryPromptContext(
            meetingId: meetingId,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000.125),
            calendarEvent: CalendarEventRecord(
                now: .now,
                event: CalendarEvent(
                    id: "planning-review",
                    calendarID: "work",
                    calendarName: "Work",
                    calendarColorHex: "#000000",
                    platformId: "planning-review",
                    title: "Planning <Review>",
                    description: "Discuss the \"next step\".",
                    icalUid: "planning&review@example.com",
                    recurrenceId: "",
                    startDate: Date(timeIntervalSince1970: 1_700_003_600.25),
                    endDate: Date(timeIntervalSince1970: 1_700_007_200.5),
                    isAllDay: false,
                    conferenceURI: nil
                ),
                key: CalendarEventKey(icalUid: "planning&review@example.com", recurrenceId: "")
            ),
            projectName: "Customer & Partner",
            projectDescription: "Discuss <launch> and the \"next step\"."
        )

        #expect(context.xml == """
        <context>
          <meeting>
            <id>019E61FD-B5D6-7A04-AC25-4B820FE951E6</id>
            <recorded_at>2023-11-14T22:13:20.125Z</recorded_at>
          </meeting>

          <calendar_event>
            <ical_uid>planning&amp;review@example.com</ical_uid>
            <title>Planning &lt;Review&gt;</title>
            <description>Discuss the &quot;next step&quot;.</description>
            <start>2023-11-14T23:13:20.250Z</start>
            <end>2023-11-15T00:13:20.500Z</end>
          </calendar_event>

          <project>
            <name>Customer &amp; Partner</name>
            <description>Discuss &lt;launch&gt; and the &quot;next step&quot;.</description>
          </project>
        </context>
        """)
    }

    @Test
    func xmlOmitsUnavailableOptionalSections() {
        let meetingId = UUID()
        let context = SummaryPromptContext(
            meetingId: meetingId,
            recordedAt: Date(timeIntervalSince1970: 0),
            calendarEvent: nil,
            projectName: "  ",
            projectDescription: "Description"
        )

        #expect(context.xml.contains("<id>\(meetingId.uuidString)</id>"))
        #expect(!context.xml.contains("<calendar_event>"))
        #expect(!context.xml.contains("<project>"))
    }

    @Test
    func xmlIncludesPreviousMeetingMetadataWithoutSummaryBody() throws {
        let previousMeetingId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E7"))
        let previousMeeting = SummaryPreviousMeetingMetadata(
            meetingId: previousMeetingId,
            name: "Planning & Review",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000.125),
            calendarStart: Date(timeIntervalSince1970: 1_700_000_100.25),
            calendarEnd: Date(timeIntervalSince1970: 1_700_003_700.5)
        )
        let context = SummaryPromptContext(
            meetingId: .v7(),
            recordedAt: .now,
            calendarEvent: nil,
            projectName: nil,
            projectDescription: nil,
            previousMeetings: [previousMeeting]
        )

        #expect(context.xml.contains("<previous_meetings>"))
        #expect(context.xml.contains("<meeting_id>\(previousMeetingId.uuidString)</meeting_id>"))
        #expect(context.xml.contains("<name>Planning &amp; Review</name>"))
        #expect(context.xml.contains("<recorded_at>2023-11-14T22:13:20.125Z</recorded_at>"))
        #expect(context.xml.contains("<start>2023-11-14T22:15:00.250Z</start>"))
        #expect(context.xml.contains("<end>2023-11-14T23:15:00.500Z</end>"))
        #expect(!context.xml.contains("<summary"))
    }
}
#endif
// swiftformat:enable indent
