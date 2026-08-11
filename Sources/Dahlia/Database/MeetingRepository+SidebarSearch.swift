import Foundation
import GRDB

extension MeetingRepository {
    nonisolated static func searchMeetingSidebarPage(
        vaultId: UUID,
        query: String,
        after cursor: MeetingSidebarCursor? = nil,
        limit: Int,
        dbQueue: DatabaseQueue
    ) async throws -> MeetingSidebarPage {
        try await searchMeetingSidebarPage(
            vaultId: vaultId,
            criteria: MeetingSearchCriteria(text: query),
            after: cursor,
            limit: limit,
            dbQueue: dbQueue
        )
    }

    nonisolated static func searchMeetingSidebarPage(
        vaultId: UUID,
        criteria: MeetingSearchCriteria,
        after cursor: MeetingSidebarCursor? = nil,
        limit: Int,
        dbQueue: DatabaseQueue
    ) async throws -> MeetingSidebarPage {
        let searchTask = Task.detached(priority: .userInitiated) {
            if criteria.isEmpty {
                try dbQueue.read { db in
                    try fetchMeetingSidebarPage(
                        vaultId: vaultId,
                        after: cursor,
                        limit: limit,
                        in: db
                    )
                }
            } else {
                try performMeetingSidebarSearch(
                    vaultId: vaultId,
                    criteria: criteria,
                    after: cursor,
                    limit: limit,
                    dbQueue: dbQueue
                )
            }
        }
        return try await withTaskCancellationHandler {
            try await searchTask.value
        } onCancel: {
            searchTask.cancel()
        }
    }

    nonisolated static func sidebarCursorFilter(
        _ cursor: MeetingSidebarCursor?
    ) -> (condition: String, arguments: StatementArguments) {
        guard let cursor else { return ("", []) }
        return (
            """
            AND (
                \(sidebarRecordingStartedAtSQL) < ?
                OR (\(sidebarRecordingStartedAtSQL) = ? AND meetings.id < ?)
            )
            """,
            [cursor.effectiveRecordingStartedAt, cursor.effectiveRecordingStartedAt, cursor.meetingId]
        )
    }

    private nonisolated static let sidebarSearchChunkSize = 200

    private nonisolated static func performMeetingSidebarSearch(
        vaultId: UUID,
        criteria: MeetingSearchCriteria,
        after cursor: MeetingSidebarCursor?,
        limit: Int,
        dbQueue: DatabaseQueue
    ) throws -> MeetingSidebarPage {
        let projects = try dbQueue.read { db in
            try ProjectRecord.fetchResolvedAll(vaultId: vaultId, in: db)
        }
        let projectPaths = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.path) })
        let includedProjectIDs = descendantProjectIDs(
            selectedIDs: criteria.projectIDs,
            projects: projects
        )
        var candidateCursor = cursor
        var matches: [MeetingSidebarItem] = []
        var reachedEnd = false

        while matches.count <= limit, !reachedEnd {
            try Task.checkCancellation()
            let candidates = try dbQueue.read { db in
                try fetchMeetingSearchCandidates(
                    vaultId: vaultId,
                    criteria: criteria,
                    includedProjectIDs: includedProjectIDs,
                    after: candidateCursor,
                    limit: sidebarSearchChunkSize,
                    in: db
                )
            }
            reachedEnd = candidates.count < sidebarSearchChunkSize
            guard let lastCandidate = candidates.last else { break }
            candidateCursor = lastCandidate.cursor

            for candidate in candidates {
                guard let matchContext = candidate.matchContext(
                    query: criteria.text,
                    projectPaths: projectPaths
                ) else { continue }
                matches.append(candidate.sidebarItem(
                    projectPaths: projectPaths,
                    matchContext: matchContext
                ))
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

    private nonisolated static func descendantProjectIDs(
        selectedIDs: Set<UUID>,
        projects: [ProjectRecord]
    ) -> Set<UUID> {
        guard !selectedIDs.isEmpty else { return [] }
        var result = selectedIDs
        var insertedChild = true
        while insertedChild {
            insertedChild = false
            for project in projects where project.parentProjectId.map(result.contains) == true {
                insertedChild = result.insert(project.id).inserted || insertedChild
            }
        }
        return result
    }

    private nonisolated static func fetchMeetingSearchCandidates(
        vaultId: UUID,
        criteria: MeetingSearchCriteria,
        includedProjectIDs: Set<UUID>,
        after cursor: MeetingSidebarCursor?,
        limit: Int,
        in db: Database
    ) throws -> [MeetingSidebarSearchCandidate] {
        let cursorFilter = sidebarCursorFilter(cursor)
        let metadataFilter = meetingSearchMetadataFilter(
            criteria: criteria,
            includedProjectIDs: includedProjectIDs
        )
        var arguments: StatementArguments = [vaultId]
        arguments += metadataFilter.arguments
        arguments += cursorFilter.arguments
        arguments += [limit]

        var candidates = try MeetingSidebarSearchCandidate.fetchAll(
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
                meetings.recordingStartedAt AS recordingStartedAt,
                calendar_events.title AS calendarEventTitle
            FROM meetings
            LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            WHERE meetings.vaultId = ?
            \(metadataFilter.condition)
            \(cursorFilter.condition)
            ORDER BY \(sidebarRecordingStartedAtSQL) DESC, meetings.id DESC
            LIMIT ?
            """,
            arguments: arguments
        )
        try attachTags(to: &candidates, in: db)
        return candidates
    }

    private nonisolated static func meetingSearchMetadataFilter(
        criteria: MeetingSearchCriteria,
        includedProjectIDs: Set<UUID>
    ) -> (condition: String, arguments: StatementArguments) {
        var conditions: [String] = []
        var arguments: StatementArguments = []
        if let startDate = criteria.startDate {
            conditions.append("\(sidebarRecordingStartedAtSQL) >= ?")
            arguments += [startDate]
        }
        if let endDate = criteria.endDate {
            conditions.append("\(sidebarRecordingStartedAtSQL) < ?")
            arguments += [endDate]
        }
        if !criteria.projectIDs.isEmpty {
            let placeholders = sqlPlaceholders(count: includedProjectIDs.count)
            conditions.append("meetings.projectId IN (\(placeholders))")
            arguments += StatementArguments(includedProjectIDs.sorted { $0.uuidString < $1.uuidString })
        }
        if !criteria.tagIDs.isEmpty {
            let placeholders = sqlPlaceholders(count: criteria.tagIDs.count)
            conditions.append(
                """
                EXISTS (
                    SELECT 1
                    FROM meeting_tags search_meeting_tags
                    WHERE search_meeting_tags.meetingId = meetings.id
                      AND search_meeting_tags.tagId IN (\(placeholders))
                )
                """
            )
            arguments += StatementArguments(criteria.tagIDs.sorted())
        }
        return (
            conditions.map { "AND \($0)" }.joined(separator: "\n"),
            arguments
        )
    }

    private nonisolated static func attachTags(
        to candidates: inout [MeetingSidebarSearchCandidate],
        in db: Database
    ) throws {
        guard !candidates.isEmpty else { return }
        let meetingIDs = candidates.map(\.meetingId)
        let placeholders = sqlPlaceholders(count: meetingIDs.count)
        let tagRows = try Row.fetchAll(
            db,
            sql: """
            SELECT
                meeting_tags.meetingId AS meetingId,
                tags.name AS tagName,
                tags.colorHex AS tagColorHex
            FROM meeting_tags
            JOIN tags ON tags.id = meeting_tags.tagId
            WHERE meeting_tags.meetingId IN (\(placeholders))
            ORDER BY meeting_tags.meetingId, tags.id
            """,
            arguments: StatementArguments(meetingIDs)
        )
        var tagsByMeetingID: [UUID: [MeetingSidebarSearchCandidate.SearchTag]] = [:]
        for row in tagRows {
            let meetingID: UUID = row["meetingId"]
            tagsByMeetingID[meetingID, default: []].append(MeetingSidebarSearchCandidate.SearchTag(
                name: row["tagName"],
                colorHex: row["tagColorHex"]
            ))
        }
        for index in candidates.indices {
            candidates[index].tags = tagsByMeetingID[candidates[index].meetingId] ?? []
        }
    }

    private nonisolated static func sqlPlaceholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
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
    let recordingStartedAt: Date?
    let calendarEventTitle: String?
    var tags: [SearchTag]

    init(row: Row) throws {
        meetingId = row["meetingId"]
        vaultId = row["vaultId"]
        projectId = row["projectId"]
        meetingName = row["meetingName"]
        meetingDescription = row["meetingDescription"]
        status = row["status"]
        duration = row["duration"]
        createdAt = row["createdAt"]
        recordingStartedAt = row["recordingStartedAt"]
        calendarEventTitle = row["calendarEventTitle"]
        tags = []
    }

    var cursor: MeetingSidebarCursor {
        MeetingSidebarCursor(
            effectiveRecordingStartedAt: recordingStartedAt ?? createdAt,
            meetingId: meetingId
        )
    }

    func matchContext(
        query: String,
        projectPaths: [UUID: String]
    ) -> MeetingSearchMatchContext? {
        if query.isEmpty || meetingName.localizedStandardContains(query) {
            return MeetingSearchMatchContext(kind: .title, text: meetingName)
        }
        if meetingDescription.localizedStandardContains(query) {
            return MeetingSearchMatchContext(
                kind: .description,
                text: Self.snippet(from: meetingDescription, matching: query)
            )
        }
        if let calendarEventTitle, calendarEventTitle.localizedStandardContains(query) {
            return MeetingSearchMatchContext(kind: .calendar, text: calendarEventTitle)
        }
        if let tag = tags.first(where: { $0.name.localizedStandardContains(query) }) {
            return MeetingSearchMatchContext(kind: .tag, text: tag.name, colorHex: tag.colorHex)
        }
        if let projectPath = projectId.flatMap({ projectPaths[$0] }),
           projectPath.localizedStandardContains(query) {
            return MeetingSearchMatchContext(kind: .project, text: projectPath)
        }
        return nil
    }

    func sidebarItem(
        projectPaths: [UUID: String],
        matchContext: MeetingSearchMatchContext
    ) -> MeetingSidebarItem {
        MeetingSidebarItem(
            meetingId: meetingId,
            vaultId: vaultId,
            projectId: projectId,
            projectName: projectId.flatMap { projectPaths[$0] },
            meetingName: meetingName,
            status: status,
            duration: duration,
            createdAt: createdAt,
            recordingStartedAt: recordingStartedAt,
            calendarEventTitle: calendarEventTitle,
            searchMatchContext: matchContext
        )
    }

    private static func snippet(from text: String, matching query: String) -> String {
        guard let range = text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ) else {
            return text
        }
        let contextLength = 24
        let lowerBound = text.index(range.lowerBound, offsetBy: -contextLength, limitedBy: text.startIndex)
            ?? text.startIndex
        let upperBound = text.index(range.upperBound, offsetBy: contextLength, limitedBy: text.endIndex)
            ?? text.endIndex
        let prefix = lowerBound == text.startIndex ? "" : "…"
        let suffix = upperBound == text.endIndex ? "" : "…"
        return prefix + text[lowerBound ..< upperBound] + suffix
    }

    struct SearchTag {
        let name: String
        let colorHex: String
    }
}
