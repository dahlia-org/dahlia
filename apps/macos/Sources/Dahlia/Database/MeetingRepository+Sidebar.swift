import Foundation
import GRDB

extension MeetingRepository {
    nonisolated static let sidebarRecordingStartedAtSQL = "COALESCE(meetings.recordingStartedAt, meetings.createdAt)"

    nonisolated static func fetchMeetingSidebarItems(
        ids: [UUID],
        workspaceId: UUID,
        in db: Database
    ) throws -> [MeetingSidebarItem] {
        guard !ids.isEmpty else { return [] }

        let projects = try ProjectRecord.fetchResolvedAll(workspaceId: workspaceId, in: db)
        let projectPaths = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.path) })
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        var arguments: StatementArguments = [workspaceId]
        arguments += StatementArguments(ids)

        var items = try MeetingSidebarItem.fetchAll(
            db,
            sql: """
            SELECT
                meetings.id AS meetingId,
                meetings.workspace_id AS workspace_id,
                meetings.projectId AS projectId,
                NULL AS projectName,
                meetings.name AS meetingName,
                meetings.status AS status,
                meetings.duration AS duration,
                meetings.createdAt AS createdAt,
                meetings.recordingStartedAt AS recordingStartedAt,
                calendar_events.title AS calendarEventTitle
            FROM meetings
            LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            WHERE meetings.workspace_id = ?
              AND meetings.id IN (\(placeholders))
            ORDER BY \(sidebarRecordingStartedAtSQL) DESC, meetings.id DESC
            """,
            arguments: arguments
        )
        for index in items.indices {
            items[index].projectName = items[index].projectId.flatMap { projectPaths[$0] }
        }
        return items
    }

    nonisolated static func fetchMeetingDescription(
        id meetingId: UUID,
        workspaceId: UUID,
        in db: Database
    ) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT description FROM meetings WHERE id = ? AND workspace_id = ?",
            arguments: [meetingId, workspaceId]
        )
    }

    nonisolated static func fetchMeetingSidebarPage(
        workspaceId: UUID,
        after cursor: MeetingSidebarCursor? = nil,
        limit: Int,
        in db: Database
    ) throws -> MeetingSidebarPage {
        let projects = try ProjectRecord.fetchResolvedAll(workspaceId: workspaceId, in: db)
        let projectPaths = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.path) })
        let cursorFilter = sidebarCursorFilter(cursor)

        var arguments: StatementArguments = [workspaceId]
        arguments += cursorFilter.arguments
        arguments += [limit + 1]

        var items = try MeetingSidebarItem.fetchAll(
            db,
            sql: """
            SELECT
                meetings.id AS meetingId,
                meetings.workspace_id AS workspace_id,
                meetings.projectId AS projectId,
                NULL AS projectName,
                meetings.name AS meetingName,
                meetings.status AS status,
                meetings.duration AS duration,
                meetings.createdAt AS createdAt,
                meetings.recordingStartedAt AS recordingStartedAt,
                calendar_events.title AS calendarEventTitle
            FROM meetings
            LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            WHERE meetings.workspace_id = ?
            \(cursorFilter.condition)
            ORDER BY \(sidebarRecordingStartedAtSQL) DESC, meetings.id DESC
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

    nonisolated static func fetchMeetingProjectProjection(
        workspaceId: UUID,
        recentLimit: Int,
        expandedLimits: [MeetingProjectKey: Int] = [:],
        totalLimit: Int,
        in db: Database
    ) throws -> MeetingProjectProjection {
        let projects = try ProjectRecord.fetchResolvedAll(workspaceId: workspaceId, in: db)
        let projectPaths = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.path) })
        let expandedProjectIds = expandedLimits.keys.compactMap(\.projectId)
        let excludedProjects = expandedProjectIds.isEmpty
            ? ""
            : "AND id NOT IN (\(Array(repeating: "?", count: expandedProjectIds.count).joined(separator: ", ")))"
        let unassignedKey = expandedLimits[.unassigned] == nil ? "UNION ALL SELECT NULL" : ""
        var arguments: StatementArguments = [recentLimit, workspaceId]
        arguments += StatementArguments(expandedProjectIds)
        arguments += [workspaceId, recentLimit + 1]
        // Materialize limit + 1 IDs per group before joining metadata; the extra row preserves hasMore.
        var candidateQueries = ["""
        SELECT candidate.id AS meetingId, ? AS projectRowLimit
        FROM (
            SELECT id AS projectId FROM projects WHERE workspace_id = ? \(excludedProjects)
            \(unassignedKey)
        ) AS keys
        CROSS JOIN meetings AS candidate
        WHERE candidate.id IN (
             SELECT meetings.id FROM meetings
             WHERE meetings.workspace_id = ? AND meetings.projectId IS keys.projectId
             ORDER BY \(sidebarRecordingStartedAtSQL) DESC, meetings.id DESC
             LIMIT ?
         )
        """]
        for (key, limit) in expandedLimits.sorted(by: { String(describing: $0.key) < String(describing: $1.key) }) {
            candidateQueries.append("""
            SELECT meetingId, ? AS projectRowLimit FROM (
                SELECT meetings.id AS meetingId FROM meetings
                WHERE meetings.workspace_id = ? AND meetings.projectId IS ?
                ORDER BY \(sidebarRecordingStartedAtSQL) DESC, meetings.id DESC
                LIMIT ?
            )
            """)
            arguments += [limit, workspaceId, key.projectId, limit + 1]
        }
        arguments += [totalLimit + 1]

        var rows = try Row.fetchAll(
            db,
            sql: """
            WITH candidates AS MATERIALIZED (
                \(candidateQueries.joined(separator: "\nUNION ALL\n"))
            ), ranked AS (
                SELECT
                    meetings.id AS meetingId,
                    meetings.workspace_id AS workspace_id,
                    meetings.projectId AS projectId,
                    NULL AS projectName,
                    meetings.name AS meetingName,
                    meetings.status AS status,
                    meetings.duration AS duration,
                    meetings.createdAt AS createdAt,
                    meetings.recordingStartedAt AS recordingStartedAt,
                    calendar_events.title AS calendarEventTitle,
                    ROW_NUMBER() OVER (
                        PARTITION BY meetings.projectId
                        ORDER BY \(sidebarRecordingStartedAtSQL) DESC, meetings.id DESC
                    ) AS projectRowNumber,
                    COUNT(*) OVER (PARTITION BY meetings.projectId) AS projectRowCount,
                    candidates.projectRowLimit AS projectRowLimit
                FROM candidates
                JOIN meetings ON meetings.id = candidates.meetingId
                LEFT JOIN calendar_events
                  ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
                 AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            )
            SELECT *
            FROM ranked
            WHERE projectRowNumber <= projectRowLimit
            ORDER BY COALESCE(recordingStartedAt, createdAt) DESC, meetingId DESC
            LIMIT ?
            """,
            arguments: arguments
        )
        let exceededTotalLimit = rows.count > totalLimit
        if exceededTotalLimit {
            rows.removeLast()
        }

        var itemsByKey: [MeetingProjectKey: [MeetingSidebarItem]] = [:]
        var hasMoreKeys: Set<MeetingProjectKey> = []
        var expectedCounts: [MeetingProjectKey: Int] = [:]
        for row in rows {
            var item = try MeetingSidebarItem(row: row)
            item.projectName = item.projectId.flatMap { projectPaths[$0] }
            let key = item.projectId.map(MeetingProjectKey.project) ?? .unassigned
            itemsByKey[key, default: []].append(item)
            let rowCount: Int = row["projectRowCount"]
            let rowLimit: Int = row["projectRowLimit"]
            expectedCounts[key] = min(rowCount, rowLimit)
            if rowCount > rowLimit {
                hasMoreKeys.insert(key)
            }
        }
        let truncatedKeys = Set(expectedCounts.compactMap { key, expectedCount in
            itemsByKey[key, default: []].count < expectedCount ? key : nil
        })
        let isLimited = exceededTotalLimit
            || (rows.count == totalLimit && (!hasMoreKeys.isEmpty || !truncatedKeys.isEmpty))
        let unassignedMeetingCount = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM meetings WHERE workspace_id = ? AND projectId IS NULL",
            arguments: [workspaceId]
        ) ?? 0
        return MeetingProjectProjection(
            itemsByKey: itemsByKey,
            hasMoreKeys: hasMoreKeys,
            truncatedKeys: truncatedKeys,
            isLimited: isLimited,
            unassignedMeetingCount: unassignedMeetingCount
        )
    }

    nonisolated static func fetchMeetingProjectPage(
        key: MeetingProjectKey,
        workspaceId: UUID,
        after cursor: MeetingSidebarCursor?,
        limit: Int,
        in db: Database
    ) throws -> MeetingSidebarPage {
        let projects = try ProjectRecord.fetchResolvedAll(workspaceId: workspaceId, in: db)
        let projectPaths = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.path) })
        let cursorFilter = sidebarCursorFilter(cursor)
        let projectFilter = key.projectId == nil ? "meetings.projectId IS NULL" : "meetings.projectId = ?"

        var arguments: StatementArguments = [workspaceId]
        if let projectId = key.projectId {
            arguments += [projectId]
        }
        arguments += cursorFilter.arguments
        arguments += [limit + 1]

        var items = try MeetingSidebarItem.fetchAll(
            db,
            sql: """
            SELECT
                meetings.id AS meetingId,
                meetings.workspace_id AS workspace_id,
                meetings.projectId AS projectId,
                NULL AS projectName,
                meetings.name AS meetingName,
                meetings.status AS status,
                meetings.duration AS duration,
                meetings.createdAt AS createdAt,
                meetings.recordingStartedAt AS recordingStartedAt,
                calendar_events.title AS calendarEventTitle
            FROM meetings
            LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            WHERE meetings.workspace_id = ?
              AND \(projectFilter)
              \(cursorFilter.condition)
            ORDER BY \(sidebarRecordingStartedAtSQL) DESC, meetings.id DESC
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
            groups: [],
            hasMore: hasMore,
            nextCursor: items.last.map(MeetingSidebarCursor.init)
        )
    }

    nonisolated static func fetchProjectHierarchyMeetingPage(
        projectIds: [UUID],
        workspaceId: UUID,
        dateInterval: DateInterval? = nil,
        after cursor: MeetingSidebarCursor? = nil,
        limit: Int,
        in db: Database
    ) throws -> MeetingSidebarPage {
        guard !projectIds.isEmpty else {
            return MeetingSidebarPage(items: [], groups: [], hasMore: false, nextCursor: nil)
        }
        let projects = try ProjectRecord.fetchResolvedAll(workspaceId: workspaceId, in: db)
        let projectPaths = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.path) })
        let placeholders = Array(repeating: "?", count: projectIds.count).joined(separator: ", ")
        let cursorFilter = sidebarCursorFilter(cursor)
        let dateFilter = dateInterval == nil
            ? ""
            : "AND \(sidebarRecordingStartedAtSQL) >= ? AND \(sidebarRecordingStartedAtSQL) < ?"

        var arguments: StatementArguments = [workspaceId]
        arguments += StatementArguments(projectIds)
        if let dateInterval {
            arguments += [dateInterval.start, dateInterval.end]
        }
        arguments += cursorFilter.arguments
        arguments += [limit + 1]

        var items = try MeetingSidebarItem.fetchAll(
            db,
            sql: """
            SELECT
                meetings.id AS meetingId,
                meetings.workspace_id AS workspace_id,
                meetings.projectId AS projectId,
                NULL AS projectName,
                meetings.name AS meetingName,
                meetings.status AS status,
                meetings.duration AS duration,
                meetings.createdAt AS createdAt,
                meetings.recordingStartedAt AS recordingStartedAt,
                calendar_events.title AS calendarEventTitle
            FROM meetings
            LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            WHERE meetings.workspace_id = ?
              AND meetings.projectId IN (\(placeholders))
              \(dateFilter)
              \(cursorFilter.condition)
            ORDER BY \(sidebarRecordingStartedAtSQL) DESC, meetings.id DESC
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
        workspaceId: UUID,
        in db: Database
    ) throws -> MeetingDetailItem? {
        guard var item = try MeetingDetailItem.fetchOne(
            db,
            sql: """
            SELECT
                meetings.id AS meetingId,
                meetings.workspace_id AS workspace_id,
                meetings.projectId AS projectId,
                NULL AS projectName,
                meetings.name AS meetingName,
                meetings.description AS meetingDescription,
                meetings.status AS status,
                meetings.duration AS duration,
                meetings.createdAt AS createdAt,
                meetings.recordingStartedAt AS recordingStartedAt,
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
            WHERE meetings.id = ? AND meetings.workspace_id = ?
            """,
            arguments: [meetingId, workspaceId]
        ) else { return nil }
        let projectPaths = try Dictionary(
            uniqueKeysWithValues: ProjectRecord.fetchResolvedAll(workspaceId: workspaceId, in: db)
                .map { ($0.id, $0.path) }
        )
        item.projectName = item.projectId.flatMap { projectPaths[$0] }
        return item
    }

    nonisolated static func fetchMeetingReferences(
        workspaceId: UUID,
        in db: Database
    ) throws -> [CodexChatMeetingReference] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT id, name, \(sidebarRecordingStartedAtSQL) AS recordingStartedAt
            FROM meetings
            WHERE workspace_id = ?
            ORDER BY \(sidebarRecordingStartedAtSQL) DESC, id DESC
            """,
            arguments: [workspaceId]
        ).map { row in
            CodexChatMeetingReference(
                id: row["id"],
                name: (row["name"] as String).nilIfBlank ?? L10n.newMeeting,
                recordingStartedAt: row["recordingStartedAt"]
            )
        }
    }

}
