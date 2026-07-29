import Foundation
import GRDB

extension MeetingRepository {
    nonisolated static func fetchMeetingSidebarItems(
        ids: [UUID],
        vaultId: UUID,
        in db: Database
    ) throws -> [MeetingSidebarItem] {
        guard !ids.isEmpty else { return [] }

        let projects = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
        let projectPaths = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.path) })
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        var arguments: StatementArguments = [vaultId]
        arguments += StatementArguments(ids)

        var items = try MeetingSidebarItem.fetchAll(
            db,
            sql: """
            SELECT
                meetings.id AS meetingId,
                meetings.vaultId AS vaultId,
                meetings.projectId AS projectId,
                NULL AS projectName,
                meetings.name AS meetingName,
                meetings.status AS status,
                meetings.duration AS duration,
                meetings.createdAt AS createdAt,
                calendar_events.title AS calendarEventTitle
            FROM meetings
            LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            WHERE meetings.vaultId = ?
              AND meetings.id IN (\(placeholders))
            ORDER BY meetings.createdAt DESC, meetings.id DESC
            """,
            arguments: arguments
        )
        for index in items.indices {
            items[index].projectName = items[index].projectId.flatMap { projectPaths[$0] }
        }
        return items
    }

    nonisolated static func fetchMeetingSidebarPage(
        vaultId: UUID,
        after cursor: MeetingSidebarCursor? = nil,
        limit: Int,
        in db: Database
    ) throws -> MeetingSidebarPage {
        let projects = try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
        let projectPaths = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.path) })
        let cursorFilter = sidebarCursorFilter(cursor)

        var arguments: StatementArguments = [vaultId]
        arguments += cursorFilter.arguments
        arguments += [limit + 1]

        var items = try MeetingSidebarItem.fetchAll(
            db,
            sql: """
            SELECT
                meetings.id AS meetingId,
                meetings.vaultId AS vaultId,
                meetings.projectId AS projectId,
                NULL AS projectName,
                meetings.name AS meetingName,
                meetings.status AS status,
                meetings.duration AS duration,
                meetings.createdAt AS createdAt,
                calendar_events.title AS calendarEventTitle
            FROM meetings
            LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            WHERE meetings.vaultId = ?
            \(cursorFilter.condition)
            ORDER BY meetings.createdAt DESC, meetings.id DESC
            LIMIT ?
            """,
            arguments: arguments
        )
        let hasMore = items.count > limit
        if hasMore {
            items.removeLast()
        }
        for index in items.indices {
            items[index].projectName = items[index].projectId.flatMap { projectPaths[$0] }
        }
        return MeetingSidebarPage(
            items: items,
            groups: MeetingDateGrouping.groups(from: items),
            hasMore: hasMore,
            nextCursor: items.last.map(MeetingSidebarCursor.init)
        )
    }

    nonisolated static func fetchMeetingDetail(
        id meetingId: UUID,
        vaultId: UUID,
        in db: Database
    ) throws -> MeetingDetailItem? {
        guard var item = try MeetingDetailItem.fetchOne(
            db,
            sql: """
            SELECT
                meetings.id AS meetingId,
                meetings.vaultId AS vaultId,
                meetings.projectId AS projectId,
                NULL AS projectName,
                meetings.name AS meetingName,
                meetings.description AS meetingDescription,
                meetings.status AS status,
                meetings.duration AS duration,
                meetings.createdAt AS createdAt,
                calendar_events.title AS calendarEventTitle,
                calendar_events.description AS calendarEventDescription,
                calendar_events.start AS calendarEventStart,
                calendar_events.end AS calendarEventEnd,
                calendar_events.is_all_day AS calendarEventIsAllDay,
                EXISTS(SELECT 1 FROM summaries WHERE summaries.meetingId = meetings.id) AS hasSummary,
                (
                    SELECT GROUP_CONCAT(tags.name || char(30) || tags.colorHex, char(31))
                    FROM meeting_tags
                    JOIN tags ON tags.id = meeting_tags.tagId
                    WHERE meeting_tags.meetingId = meetings.id
                ) AS tags
            FROM meetings
            LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            WHERE meetings.id = ? AND meetings.vaultId = ?
            """,
            arguments: [meetingId, vaultId]
        ) else { return nil }
        let projectPaths = try Dictionary(
            uniqueKeysWithValues: ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
                .map { ($0.id, $0.path) }
        )
        item.projectName = item.projectId.flatMap { projectPaths[$0] }
        return item
    }

    nonisolated static func fetchMeetingReferences(
        vaultId: UUID,
        in db: Database
    ) throws -> [CodexChatMeetingReference] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT id, name, createdAt
            FROM meetings
            WHERE vaultId = ?
            ORDER BY createdAt DESC, id DESC
            """,
            arguments: [vaultId]
        ).map { row in
            CodexChatMeetingReference(
                id: row["id"],
                name: (row["name"] as String).nilIfBlank ?? L10n.newMeeting,
                createdAt: row["createdAt"]
            )
        }
    }

}
