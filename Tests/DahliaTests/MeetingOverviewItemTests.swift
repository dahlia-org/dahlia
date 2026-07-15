import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingOverviewItemTests {
        @Test
        func decodesLinkedCalendarEventFromOverviewRow() throws {
            let meetingId = UUID.v7()
            let vaultId = UUID.v7()
            let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            let eventStart = Date(timeIntervalSince1970: 1_700_003_600)
            let eventEnd = eventStart.addingTimeInterval(3600)
            let dbQueue = try DatabaseQueue(path: ":memory:")

            let item = try dbQueue.read { db in
                let fetchedRow = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT
                        ? AS meetingId,
                        ? AS vaultId,
                        NULL AS projectId,
                        NULL AS projectName,
                        'Weekly sync' AS meetingName,
                        'AI description' AS meetingDescription,
                        'READY' AS status,
                        NULL AS duration,
                        ? AS createdAt,
                        'Calendar title' AS calendarEventTitle,
                        'Calendar description' AS calendarEventDescription,
                        ? AS calendarEventStart,
                        ? AS calendarEventEnd,
                        0 AS calendarEventIsAllDay,
                        0 AS hasSummary,
                        0 AS segmentCount,
                        NULL AS latestSegmentText,
                        NULL AS tags
                    """,
                    arguments: [meetingId, vaultId, createdAt, eventStart, eventEnd]
                )
                let row = try #require(fetchedRow)
                return try MeetingOverviewItem(row: row)
            }

            #expect(item.calendarEvent == CalendarEventDisplayInfo(
                title: "Calendar title",
                description: "Calendar description",
                startDate: eventStart,
                endDate: eventEnd,
                isAllDay: false
            ))
            #expect(item.meetingDescription == "AI description")
        }
    }
#endif
