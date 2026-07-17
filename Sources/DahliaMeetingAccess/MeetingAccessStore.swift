import DahliaRuntimeSupport
import Foundation
import GRDB

public final class MeetingAccessStore: Sendable {
    public static var defaultDatabaseURL: URL {
        DahliaApplicationSupport.currentDirectoryURL
            .appending(path: "dahlia.sqlite")
    }

    private let database: DatabaseQueue
    public let vaultID: UUID

    public init(databaseURL: URL = MeetingAccessStore.defaultDatabaseURL, vaultID: UUID) throws {
        var configuration = Configuration()
        configuration.readonly = true
        database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        self.vaultID = vaultID
    }

    public func scopedVault() throws -> ScopedVault {
        try database.read(fetchVault(in:))
    }

    public func queryMeetings(_ query: MeetingQuery = MeetingQuery()) throws -> MeetingQueryPage {
        guard (1 ... 100).contains(query.limit) else {
            throw MeetingAccessError.invalidLimit(maximum: 100)
        }
        let cursor = try query.cursor.map { try MeetingCursor.decode($0, vaultID: vaultID) }
        let queryComponents = meetingQueryComponents(query, cursor: cursor)

        return try database.read { db in
            let vault = try fetchVault(in: db)
            let rows = try meetingRows(in: db, components: queryComponents)
            let hasMore = rows.count > query.limit
            let pageRows = hasMore ? Array(rows.prefix(query.limit)) : rows
            let meetings = pageRows.map(Self.metadata(from:))
            let nextCursor = hasMore ? meetings.last.map {
                MeetingCursor(vaultID: vaultID, createdAt: $0.createdAt, meetingID: $0.id).encoded()
            } : nil
            return MeetingQueryPage(vault: vault, meetings: meetings, nextCursor: nextCursor)
        }
    }

    private func meetingQueryComponents(_ query: MeetingQuery, cursor: MeetingCursor?) -> QueryComponents {
        var components = QueryComponents(predicates: ["meetings.vaultId = ?"], arguments: [vaultID])
        let trimmedQuery = query.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedQuery, !trimmedQuery.isEmpty {
            components.appendSearch(pattern: "%\(escapedLikePattern(trimmedQuery))%")
        }
        let trimmedProject = query.project?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedProject, !trimmedProject.isEmpty {
            components.predicates.append("projects.name = ? COLLATE NOCASE")
            components.arguments += [trimmedProject]
        }
        if let createdFrom = query.createdFrom {
            components.predicates.append("meetings.createdAt >= ?")
            components.arguments += [createdFrom]
        }
        if let createdBefore = query.createdBefore {
            components.predicates.append("meetings.createdAt < ?")
            components.arguments += [createdBefore]
        }
        if let cursor {
            components.predicates.append("(meetings.createdAt < ? OR (meetings.createdAt = ? AND meetings.id < ?))")
            components.arguments += [cursor.createdAt, cursor.createdAt, cursor.meetingID]
        }
        components.arguments += [query.limit + 1]
        return components
    }

    private func meetingRows(in db: Database, components: QueryComponents) throws -> [Row] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT
                meetings.id,
                meetings.name,
                meetings.description,
                projects.name AS project,
                calendar_events.title AS calendarTitle,
                meetings.status,
                meetings.duration,
                meetings.createdAt,
                summaries.meetingId IS NOT NULL AS hasSummary,
                (SELECT COUNT(*) FROM transcript_segments
                 WHERE transcript_segments.meetingId = meetings.id
                   AND transcript_segments.isConfirmed = 1) AS transcriptSegmentCount,
                (SELECT GROUP_CONCAT(tags.name, char(31))
                 FROM meeting_tags JOIN tags ON tags.id = meeting_tags.tagId
                 WHERE meeting_tags.meetingId = meetings.id) AS tags
            FROM meetings
            LEFT JOIN projects
              ON projects.id = meetings.projectId
             AND projects.vaultId = meetings.vaultId
            LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            LEFT JOIN summaries ON summaries.meetingId = meetings.id
            WHERE \(components.predicates.joined(separator: " AND "))
            ORDER BY meetings.createdAt DESC, meetings.id DESC
            LIMIT ?
            """,
            arguments: components.arguments
        )
    }

    public func meeting(id: UUID) throws -> MeetingDetail {
        try database.read { db in
            let vault = try fetchVault(in: db)
            guard let row = try meetingRow(id: id, in: db) else {
                throw MeetingAccessError.meetingNotFound
            }
            let document: String? = row["summaryDocument"]
            let summary: String?
            do {
                summary = try document.map(StoredSummaryDocumentMarkdownRenderer.render(json:))
            } catch {
                throw MeetingAccessError.invalidSummaryDocument
            }
            return MeetingDetail(vault: vault, meeting: Self.metadata(from: row), summary: summary)
        }
    }

    public func transcript(meetingID: UUID, limit: Int = 200, cursor: String? = nil) throws -> TranscriptPage {
        guard (1 ... 500).contains(limit) else {
            throw MeetingAccessError.invalidLimit(maximum: 500)
        }
        let decodedCursor = try cursor.map {
            try TranscriptCursor.decode($0, vaultID: vaultID, meetingID: meetingID)
        }

        return try database.read { db in
            let vault = try fetchVault(in: db)
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM meetings WHERE id = ? AND vaultId = ?)",
                arguments: [meetingID, vaultID]
            ) == true else {
                throw MeetingAccessError.meetingNotFound
            }
            let rows = try transcriptRows(
                in: db,
                meetingID: meetingID,
                limit: limit,
                cursor: decodedCursor
            )
            let hasMore = rows.count > limit
            let pageRows = hasMore ? Array(rows.prefix(limit)) : rows
            let segments = pageRows.map(Self.transcriptEntry(from:))
            let nextCursor = hasMore ? segments.last.map {
                TranscriptCursor(
                    vaultID: vaultID,
                    meetingID: meetingID,
                    startedAt: $0.startedAt,
                    segmentID: $0.id
                ).encoded()
            } : nil
            return TranscriptPage(vault: vault, meetingID: meetingID, segments: segments, nextCursor: nextCursor)
        }
    }

    private func transcriptRows(
        in db: Database,
        meetingID: UUID,
        limit: Int,
        cursor: TranscriptCursor?
    ) throws -> [Row] {
        var cursorPredicate = ""
        var arguments: StatementArguments = [meetingID, vaultID]
        if let cursor {
            cursorPredicate = "AND (segments.startTime > ? OR (segments.startTime = ? AND segments.id > ?))"
            arguments += [cursor.startedAt, cursor.startedAt, cursor.segmentID]
        }
        arguments += [limit + 1]
        return try Row.fetchAll(
            db,
            sql: """
            SELECT
                segments.id,
                segments.text,
                segments.speakerLabel,
                segments.startTime,
                segments.endTime,
                meetings.createdAt AS meetingCreatedAt,
                sessions.startedAt AS sessionStartedAt,
                sessions.offsetSeconds AS sessionOffsetSeconds
            FROM transcript_segments AS segments
            JOIN meetings ON meetings.id = segments.meetingId
            LEFT JOIN recording_sessions AS sessions
              ON sessions.id = segments.sessionId
             AND sessions.meetingId = segments.meetingId
            WHERE segments.meetingId = ?
              AND meetings.vaultId = ?
              AND segments.isConfirmed = 1
              \(cursorPredicate)
            ORDER BY segments.startTime ASC, segments.id ASC
            LIMIT ?
            """,
            arguments: arguments
        )
    }

    private static func transcriptEntry(from row: Row) -> TranscriptEntry {
        let startedAt: Date = row["startTime"]
        let meetingCreatedAt: Date = row["meetingCreatedAt"]
        let sessionStartedAt: Date? = row["sessionStartedAt"]
        let sessionOffsetSeconds: Double? = row["sessionOffsetSeconds"]
        let elapsed = if let sessionStartedAt, let sessionOffsetSeconds {
            sessionOffsetSeconds + startedAt.timeIntervalSince(sessionStartedAt)
        } else {
            startedAt.timeIntervalSince(meetingCreatedAt)
        }
        return TranscriptEntry(
            id: row["id"],
            text: row["text"],
            speaker: row["speakerLabel"],
            startedAt: startedAt,
            endedAt: row["endTime"],
            elapsedSeconds: max(0, elapsed)
        )
    }

    private func fetchVault(in db: Database) throws -> ScopedVault {
        let meetingColumns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('meetings')")
        let summaryColumns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('summaries')"))
        let legacySummaryColumns: Set = ["summary", "googleFileId", "vaultRelativePath"]
        guard meetingColumns.contains("description"),
              summaryColumns.contains("document"),
              summaryColumns.isDisjoint(with: legacySummaryColumns)
        else {
            throw MeetingAccessError.databaseUpgradeRequired
        }
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT id, name FROM vaults WHERE id = ?",
            arguments: [vaultID]
        ) else {
            throw MeetingAccessError.vaultNotFound
        }
        return ScopedVault(id: row["id"], name: row["name"])
    }

    private func meetingRow(id: UUID, in db: Database) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: """
            SELECT
                meetings.id,
                meetings.name,
                meetings.description,
                projects.name AS project,
                calendar_events.title AS calendarTitle,
                meetings.status,
                meetings.duration,
                meetings.createdAt,
                summaries.meetingId IS NOT NULL AS hasSummary,
                summaries.document AS summaryDocument,
                (SELECT COUNT(*) FROM transcript_segments
                 WHERE transcript_segments.meetingId = meetings.id
                   AND transcript_segments.isConfirmed = 1) AS transcriptSegmentCount,
                (SELECT GROUP_CONCAT(tags.name, char(31))
                 FROM meeting_tags JOIN tags ON tags.id = meeting_tags.tagId
                 WHERE meeting_tags.meetingId = meetings.id) AS tags
            FROM meetings
            LEFT JOIN projects
              ON projects.id = meetings.projectId
             AND projects.vaultId = meetings.vaultId
            LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            LEFT JOIN summaries ON summaries.meetingId = meetings.id
            WHERE meetings.id = ? AND meetings.vaultId = ?
            """,
            arguments: [id, vaultID]
        )
    }

    private static func metadata(from row: Row) -> MeetingMetadata {
        let tagString: String? = row["tags"]
        return MeetingMetadata(
            id: row["id"],
            name: row["name"],
            description: row["description"],
            project: row["project"],
            calendarTitle: row["calendarTitle"],
            status: row["status"],
            durationSeconds: row["duration"],
            createdAt: row["createdAt"],
            hasSummary: row["hasSummary"],
            transcriptSegmentCount: row["transcriptSegmentCount"],
            tags: tagString?.split(separator: "\u{1F}").map(String.init) ?? []
        )
    }

    private func escapedLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

private struct QueryComponents {
    var predicates: [String]
    var arguments: StatementArguments

    mutating func appendSearch(pattern: String) {
        predicates.append("""
        (
            meetings.name LIKE ? ESCAPE '\\' COLLATE NOCASE
            OR meetings.description LIKE ? ESCAPE '\\' COLLATE NOCASE
            OR calendar_events.title LIKE ? ESCAPE '\\' COLLATE NOCASE
            OR projects.name LIKE ? ESCAPE '\\' COLLATE NOCASE
            OR EXISTS (
                SELECT 1 FROM meeting_tags
                JOIN tags ON tags.id = meeting_tags.tagId
                WHERE meeting_tags.meetingId = meetings.id
                  AND tags.name LIKE ? ESCAPE '\\' COLLATE NOCASE
            )
        )
        """)
        for _ in 0 ..< 5 {
            arguments += [pattern]
        }
    }
}

private struct MeetingCursor: Codable {
    let vaultID: UUID
    let createdAt: Date
    let meetingID: UUID

    func encoded() -> String {
        (try? JSONEncoder().encode(self).base64EncodedString()) ?? ""
    }

    static func decode(_ value: String, vaultID: UUID) throws -> Self {
        guard let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(Self.self, from: data),
              cursor.vaultID == vaultID else {
            throw MeetingAccessError.invalidCursor
        }
        return cursor
    }
}

private struct TranscriptCursor: Codable {
    let vaultID: UUID
    let meetingID: UUID
    let startedAt: Date
    let segmentID: UUID

    func encoded() -> String {
        (try? JSONEncoder().encode(self).base64EncodedString()) ?? ""
    }

    static func decode(_ value: String, vaultID: UUID, meetingID: UUID) throws -> Self {
        guard let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(Self.self, from: data),
              cursor.vaultID == vaultID,
              cursor.meetingID == meetingID else {
            throw MeetingAccessError.invalidCursor
        }
        return cursor
    }
}
