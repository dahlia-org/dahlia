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

        @Test
        func resolvesNestedProjectNameAsLogicalPath() throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/sidebar-project-path",
                name: "Vault",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let root = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                parentProjectId: nil,
                name: "Acme",
                createdAt: .now,
                projectType: .customer
            )
            let child = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                parentProjectId: root.id,
                name: "Platform",
                createdAt: .now,
                projectType: nil
            )
            try manager.dbQueue.write { db in
                try vault.insert(db)
                try root.insert(db)
                try child.insert(db)
            }
            var meetings = [
                MeetingOverviewItem(
                    meetingId: .v7(),
                    vaultId: vault.id,
                    projectId: child.id,
                    projectName: nil,
                    meetingName: "Planning",
                    status: .ready,
                    duration: nil,
                    createdAt: .now,
                    hasSummary: false,
                    segmentCount: 0,
                    latestSegmentText: nil,
                    tags: []
                ),
            ]

            try manager.dbQueue.read { db in
                try SidebarViewModel.resolveProjectPaths(
                    in: &meetings,
                    vaultId: vault.id,
                    database: db
                )
            }

            #expect(meetings.first?.projectName == "Acme/Platform")
        }
    }
#endif
