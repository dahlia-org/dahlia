import Foundation
import GRDB

extension MeetingRepository {
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

    nonisolated static func searchMeetingSidebarPage(
        vaultId: UUID,
        query: String,
        after cursor: MeetingSidebarCursor? = nil,
        limit: Int,
        dbQueue: DatabaseQueue
    ) async throws -> MeetingSidebarPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            let fetchTask = Task.detached(priority: .userInitiated) {
                try dbQueue.read { db in
                    try fetchMeetingSidebarPage(
                        vaultId: vaultId,
                        after: cursor,
                        limit: limit,
                        in: db
                    )
                }
            }
            return try await withTaskCancellationHandler {
                try await fetchTask.value
            } onCancel: {
                fetchTask.cancel()
            }
        }

        let searchTask = Task.detached(priority: .userInitiated) {
            try performMeetingSidebarSearch(
                vaultId: vaultId,
                query: query,
                after: cursor,
                limit: limit,
                dbQueue: dbQueue
            )
        }
        return try await withTaskCancellationHandler {
            try await searchTask.value
        } onCancel: {
            searchTask.cancel()
        }
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

    private nonisolated static let sidebarSearchChunkSize = 200

    private nonisolated static func performMeetingSidebarSearch(
        vaultId: UUID,
        query: String,
        after cursor: MeetingSidebarCursor?,
        limit: Int,
        dbQueue: DatabaseQueue
    ) throws -> MeetingSidebarPage {
        let projectPaths = try dbQueue.read { db in
            try Dictionary(
                uniqueKeysWithValues: ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
                    .map { ($0.id, $0.path) }
            )
        }
        var candidateCursor = cursor
        var matches: [MeetingSidebarItem] = []
        var reachedEnd = false

        while matches.count <= limit, !reachedEnd {
            try Task.checkCancellation()
            let candidates = try dbQueue.read { db in
                try fetchMeetingSearchCandidates(
                    vaultId: vaultId,
                    after: candidateCursor,
                    limit: sidebarSearchChunkSize,
                    in: db
                )
            }
            reachedEnd = candidates.count < sidebarSearchChunkSize
            guard let lastCandidate = candidates.last else { break }
            candidateCursor = lastCandidate.cursor

            for candidate in candidates where candidate.matches(query, projectPaths: projectPaths) {
                matches.append(candidate.sidebarItem(projectPaths: projectPaths))
                if matches.count > limit {
                    break
                }
            }
        }

        let hasMore = matches.count > limit
        if hasMore {
            matches.removeLast()
        }
        return MeetingSidebarPage(
            items: matches,
            groups: MeetingDateGrouping.groups(from: matches),
            hasMore: hasMore,
            nextCursor: matches.last.map(MeetingSidebarCursor.init)
        )
    }

    private nonisolated static func sidebarCursorFilter(
        _ cursor: MeetingSidebarCursor?
    ) -> (condition: String, arguments: StatementArguments) {
        guard let cursor else { return ("", []) }
        return (
            """
            AND (
                meetings.createdAt < ?
                OR (meetings.createdAt = ? AND meetings.id < ?)
            )
            """,
            [cursor.createdAt, cursor.createdAt, cursor.meetingId]
        )
    }

    private nonisolated static func fetchMeetingSearchCandidates(
        vaultId: UUID,
        after cursor: MeetingSidebarCursor?,
        limit: Int,
        in db: Database
    ) throws -> [MeetingSidebarSearchCandidate] {
        let cursorFilter = sidebarCursorFilter(cursor)
        var arguments: StatementArguments = [vaultId]
        arguments += cursorFilter.arguments
        arguments += [limit]
        return try MeetingSidebarSearchCandidate.fetchAll(
            db,
            sql: """
            SELECT
                meetings.id AS meetingId,
                meetings.vaultId AS vaultId,
                meetings.projectId AS projectId,
                meetings.name AS meetingName,
                meetings.description AS meetingDescription,
                meetings.status AS status,
                meetings.duration AS duration,
                meetings.createdAt AS createdAt,
                calendar_events.title AS calendarEventTitle,
                (
                    SELECT GROUP_CONCAT(tags.name, char(31))
                    FROM meeting_tags
                    JOIN tags ON tags.id = meeting_tags.tagId
                    WHERE meeting_tags.meetingId = meetings.id
                ) AS tagNames
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
    }
}

private struct MeetingSidebarSearchCandidate: FetchableRecord {
    let meetingId: UUID
    let vaultId: UUID
    let projectId: UUID?
    let meetingName: String
    let meetingDescription: String
    let status: MeetingStatus
    let duration: TimeInterval?
    let createdAt: Date
    let calendarEventTitle: String?
    let tagNames: String

    init(row: Row) throws {
        meetingId = row["meetingId"]
        vaultId = row["vaultId"]
        projectId = row["projectId"]
        meetingName = row["meetingName"]
        meetingDescription = row["meetingDescription"]
        status = row["status"]
        duration = row["duration"]
        createdAt = row["createdAt"]
        calendarEventTitle = row["calendarEventTitle"]
        tagNames = row["tagNames"] ?? ""
    }

    var cursor: MeetingSidebarCursor {
        MeetingSidebarCursor(createdAt: createdAt, meetingId: meetingId)
    }

    func matches(_ query: String, projectPaths: [UUID: String]) -> Bool {
        meetingName.localizedStandardContains(query)
            || meetingDescription.localizedStandardContains(query)
            || (calendarEventTitle?.localizedStandardContains(query) ?? false)
            || tagNames.localizedStandardContains(query)
            || (projectId.flatMap { projectPaths[$0] }?.localizedStandardContains(query) ?? false)
    }

    func sidebarItem(projectPaths: [UUID: String]) -> MeetingSidebarItem {
        MeetingSidebarItem(
            meetingId: meetingId,
            vaultId: vaultId,
            projectId: projectId,
            projectName: projectId.flatMap { projectPaths[$0] },
            meetingName: meetingName,
            status: status,
            duration: duration,
            createdAt: createdAt,
            calendarEventTitle: calendarEventTitle
        )
    }
}
