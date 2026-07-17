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
            let summaryDocument: JSONValue?
            do {
                if let document {
                    let decoded = try StoredSummaryDocumentMarkdownRenderer.decode(json: document)
                    summary = StoredSummaryDocumentMarkdownRenderer.render(decoded)
                    summaryDocument = try StoredSummaryDocumentMarkdownRenderer.jsonValue(decoded)
                } else {
                    summary = nil
                    summaryDocument = nil
                }
            } catch {
                throw MeetingAccessError.invalidSummaryDocument
            }
            return MeetingDetail(
                vault: vault,
                meeting: Self.metadata(from: row),
                summary: summary,
                summaryDocument: summaryDocument
            )
        }
    }

    public func transcript(
        meetingID: UUID,
        fromElapsedSeconds: Double? = nil,
        toElapsedSeconds: Double? = nil,
        limit: Int = 200,
        cursor: String? = nil
    ) throws -> TranscriptPage {
        guard (1 ... 500).contains(limit) else {
            throw MeetingAccessError.invalidLimit(maximum: 500)
        }
        try validateTimeRange(from: fromElapsedSeconds, to: toElapsedSeconds)
        let decodedCursor = try cursor.map {
            try TranscriptCursor.decode(
                $0,
                vaultID: vaultID,
                meetingID: meetingID,
                fromElapsedSeconds: fromElapsedSeconds,
                toElapsedSeconds: toElapsedSeconds
            )
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
                fromElapsedSeconds: fromElapsedSeconds,
                toElapsedSeconds: toElapsedSeconds,
                cursor: decodedCursor,
                limit: limit
            )
            let entries = rows.map(Self.transcriptEntry(from:))
            let hasMore = entries.count > limit
            let segments = hasMore ? Array(entries.prefix(limit)) : entries
            let nextCursor = hasMore ? segments.last.map {
                TranscriptCursor(
                    vaultID: vaultID,
                    meetingID: meetingID,
                    startedAt: $0.startedAt,
                    elapsedSeconds: $0.elapsedSeconds,
                    segmentID: $0.id,
                    fromElapsedSeconds: fromElapsedSeconds,
                    toElapsedSeconds: toElapsedSeconds
                ).encoded()
            } : nil
            return TranscriptPage(vault: vault, meetingID: meetingID, segments: segments, nextCursor: nextCursor)
        }
    }

    private func transcriptRows(
        in db: Database,
        meetingID: UUID,
        fromElapsedSeconds: Double?,
        toElapsedSeconds: Double?,
        cursor: TranscriptCursor?,
        limit: Int
    ) throws -> [Row] {
        if fromElapsedSeconds == nil, toElapsedSeconds == nil {
            return try transcriptRowsByStartTime(in: db, meetingID: meetingID, cursor: cursor, limit: limit)
        }

        var predicates: [String] = []
        var arguments: StatementArguments = [meetingID, vaultID]
        if let fromElapsedSeconds {
            predicates.append("elapsedSeconds >= ?")
            arguments += [fromElapsedSeconds]
        }
        if let toElapsedSeconds {
            predicates.append("elapsedSeconds < ?")
            arguments += [toElapsedSeconds]
        }
        if let cursor {
            predicates.append("(elapsedSeconds > ? OR (elapsedSeconds = ? AND id > ?))")
            arguments += [cursor.elapsedSeconds, cursor.elapsedSeconds, cursor.segmentID]
        }
        let filtering = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
        arguments += [limit + 1]
        return try Row.fetchAll(
            db,
            sql: """
            WITH candidates AS (
                SELECT
                    segments.id,
                    segments.text,
                    segments.speakerLabel,
                    segments.startTime,
                    segments.endTime,
                    meetings.createdAt AS meetingCreatedAt,
                    sessions.startedAt AS sessionStartedAt,
                    sessions.offsetSeconds AS sessionOffsetSeconds,
                    \(Self.elapsedSecondsSQL(timestampColumn: "segments.startTime")) AS elapsedSeconds
                FROM transcript_segments AS segments
                JOIN meetings ON meetings.id = segments.meetingId
                LEFT JOIN recording_sessions AS sessions
                  ON sessions.id = segments.sessionId
                 AND sessions.meetingId = segments.meetingId
                WHERE segments.meetingId = ?
                  AND meetings.vaultId = ?
                  AND segments.isConfirmed = 1
            )
            SELECT * FROM candidates
            \(filtering)
            ORDER BY elapsedSeconds ASC, id ASC
            LIMIT ?
            """,
            arguments: arguments
        )
    }

    private func transcriptRowsByStartTime(
        in db: Database,
        meetingID: UUID,
        cursor: TranscriptCursor?,
        limit: Int
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
                sessions.offsetSeconds AS sessionOffsetSeconds,
                \(Self.elapsedSecondsSQL(timestampColumn: "segments.startTime")) AS elapsedSeconds
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
        let elapsed: Double = row["elapsedSeconds"]
        return TranscriptEntry(
            id: row["id"],
            text: row["text"],
            speaker: row["speakerLabel"],
            startedAt: startedAt,
            endedAt: row["endTime"],
            elapsedSeconds: max(0, elapsed),
            endedElapsedSeconds: Self.elapsedSeconds(
                at: row["endTime"],
                meetingCreatedAt: meetingCreatedAt,
                sessionStartedAt: sessionStartedAt,
                sessionOffsetSeconds: sessionOffsetSeconds
            ),
            timestamp: Self.timestamp(elapsedSeconds: max(0, elapsed))
        )
    }

    private static func elapsedSeconds(
        at date: Date?,
        meetingCreatedAt: Date,
        sessionStartedAt: Date?,
        sessionOffsetSeconds: Double?
    ) -> Double? {
        guard let date else { return nil }
        let elapsed = if let sessionStartedAt, let sessionOffsetSeconds {
            sessionOffsetSeconds + date.timeIntervalSince(sessionStartedAt)
        } else {
            date.timeIntervalSince(meetingCreatedAt)
        }
        return (max(0, elapsed) * 1000).rounded() / 1000
    }

    private static func elapsedSecondsSQL(timestampColumn: String) -> String {
        """
        MAX(0, ROUND(CASE
            WHEN sessions.startedAt IS NOT NULL AND sessions.offsetSeconds IS NOT NULL
            THEN sessions.offsetSeconds
                + (julianday(\(timestampColumn)) - julianday(sessions.startedAt)) * 86400.0
            ELSE (julianday(\(timestampColumn)) - julianday(meetings.createdAt)) * 86400.0
        END, 3))
        """
    }

    private static func timestamp(elapsedSeconds: Double) -> String {
        let totalSeconds = max(0, Int(elapsedSeconds))
        return String(
            format: "%02d:%02d:%02d",
            totalSeconds / 3600,
            (totalSeconds % 3600) / 60,
            totalSeconds % 60
        )
    }

    private func validateTimeRange(from: Double?, to: Double?) throws {
        let hasValidBounds = if let from, let to { from < to } else { true }
        guard from.map({ $0.isFinite && $0 >= 0 }) ?? true,
              to.map({ $0.isFinite && $0 >= 0 }) ?? true,
              hasValidBounds else {
            throw MeetingAccessError.invalidTimeRange
        }
    }
}

extension MeetingAccessStore {
    public func screenshots(
        meetingID: UUID,
        query: ScreenshotQuery = ScreenshotQuery()
    ) throws -> MeetingScreenshotPage {
        try screenshotPageData(meetingID: meetingID, query: query, includeImageData: false).page
    }

    public func screenshotImages(
        meetingID: UUID,
        query: ScreenshotQuery
    ) throws -> (page: MeetingScreenshotPage, images: [MeetingScreenshotImage]) {
        let result = try screenshotPageData(meetingID: meetingID, query: query, includeImageData: true)
        let images = result.payloads.compactMap(Self.encodedScreenshot)
        return (
            MeetingScreenshotPage(
                vault: result.page.vault,
                meetingID: result.page.meetingID,
                screenshots: images.map(\.metadata),
                nextCursor: result.page.nextCursor
            ),
            images
        )
    }

    private func screenshotPageData(
        meetingID: UUID,
        query: ScreenshotQuery,
        includeImageData: Bool
    ) throws -> ScreenshotPageData {
        guard (1 ... 100).contains(query.limit) else {
            throw MeetingAccessError.invalidLimit(maximum: 100)
        }
        try validateTimeRange(from: query.fromElapsedSeconds, to: query.toElapsedSeconds)
        let decodedCursor = try query.cursor.map {
            try ScreenshotCursor.decode(
                $0,
                vaultID: vaultID,
                meetingID: meetingID,
                fromElapsedSeconds: query.fromElapsedSeconds,
                toElapsedSeconds: query.toElapsedSeconds
            )
        }

        return try database.read { db in
            let vault = try fetchVault(in: db)
            guard try meetingExists(id: meetingID, in: db) else {
                throw MeetingAccessError.meetingNotFound
            }
            let referencedIDs = try referencedScreenshotIDs(meetingID: meetingID, in: db)
            let rows = try screenshotRows(
                meetingID: meetingID,
                query: query,
                cursor: decodedCursor,
                includeImageData: includeImageData,
                in: db
            )
            let hasMore = rows.count > query.limit
            let pageRows = hasMore ? Array(rows.prefix(query.limit)) : rows
            let screenshots = pageRows.map { Self.screenshotMetadata(from: $0, referencedIDs: referencedIDs) }
            let nextCursor = hasMore ? screenshots.last.map {
                ScreenshotCursor(
                    vaultID: vaultID,
                    meetingID: meetingID,
                    elapsedSeconds: $0.elapsedSeconds,
                    screenshotID: $0.id,
                    fromElapsedSeconds: query.fromElapsedSeconds,
                    toElapsedSeconds: query.toElapsedSeconds
                ).encoded()
            } : nil
            let payloads = includeImageData ? zip(pageRows, screenshots).map {
                ScreenshotPayload(metadata: $0.1, imageData: $0.0["imageData"])
            } : []
            return ScreenshotPageData(
                page: MeetingScreenshotPage(
                    vault: vault,
                    meetingID: meetingID,
                    screenshots: screenshots,
                    nextCursor: nextCursor
                ),
                payloads: payloads
            )
        }
    }

    public func screenshot(meetingID: UUID, screenshotID: UUID) throws -> MeetingScreenshotImage {
        guard let image = try screenshotImages(meetingID: meetingID, screenshotIDs: [screenshotID]).first else {
            throw MeetingAccessError.screenshotNotFound
        }
        return image
    }

    public func screenshotImages(meetingID: UUID, screenshotIDs: [UUID]) throws -> [MeetingScreenshotImage] {
        guard !screenshotIDs.isEmpty, screenshotIDs.count <= 10, Set(screenshotIDs).count == screenshotIDs.count else {
            throw MeetingAccessError.screenshotNotFound
        }
        let payloads: [ScreenshotPayload] = try database.read { db in
            _ = try fetchVault(in: db)
            guard try meetingExists(id: meetingID, in: db) else {
                throw MeetingAccessError.meetingNotFound
            }
            let rows = try screenshotImageRows(meetingID: meetingID, screenshotIDs: screenshotIDs, in: db)
            guard rows.count == screenshotIDs.count else {
                throw MeetingAccessError.screenshotNotFound
            }
            let referencedIDs = try referencedScreenshotIDs(meetingID: meetingID, in: db)
            let payloadsByID = Dictionary(uniqueKeysWithValues: rows.map { row in
                let metadata = Self.screenshotMetadata(from: row, referencedIDs: referencedIDs)
                return (metadata.id, ScreenshotPayload(metadata: metadata, imageData: row["imageData"]))
            })
            return try screenshotIDs.map { id in
                guard let payload = payloadsByID[id] else { throw MeetingAccessError.screenshotNotFound }
                return payload
            }
        }
        return try payloads.map { payload in
            guard let image = Self.encodedScreenshot(payload) else {
                throw MeetingAccessError.screenshotEncodingFailed
            }
            return image
        }
    }

    private static func encodedScreenshot(_ payload: ScreenshotPayload) -> MeetingScreenshotImage? {
        guard let imageData = ImageEncoder.resizedIfPossible(payload.imageData, maxLongEdge: 1024),
              let mimeType = ImageEncoder.mimeType(for: imageData) else {
            return nil
        }
        let metadata = MeetingScreenshotMetadata(
            id: payload.metadata.id,
            capturedAt: payload.metadata.capturedAt,
            elapsedSeconds: payload.metadata.elapsedSeconds,
            timestamp: payload.metadata.timestamp,
            mimeType: mimeType,
            isReferencedInSummary: payload.metadata.isReferencedInSummary
        )
        return MeetingScreenshotImage(metadata: metadata, imageData: imageData, mimeType: mimeType)
    }

    private func meetingExists(id: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM meetings WHERE id = ? AND vaultId = ?)",
            arguments: [id, vaultID]
        ) == true
    }

    private func screenshotRows(
        meetingID: UUID,
        query: ScreenshotQuery,
        cursor: ScreenshotCursor?,
        includeImageData: Bool,
        in db: Database
    ) throws -> [Row] {
        var predicates: [String] = []
        var arguments: StatementArguments = [meetingID, vaultID]
        if let from = query.fromElapsedSeconds {
            predicates.append("elapsedSeconds >= ?")
            arguments += [from]
        }
        if let to = query.toElapsedSeconds {
            predicates.append("elapsedSeconds < ?")
            arguments += [to]
        }
        if let cursor {
            predicates.append("(elapsedSeconds > ? OR (elapsedSeconds = ? AND id > ?))")
            arguments += [cursor.elapsedSeconds, cursor.elapsedSeconds, cursor.screenshotID]
        }
        let filtering = predicates.isEmpty ? "" : "WHERE \(predicates.joined(separator: " AND "))"
        let imageDataSelection = includeImageData ? "screenshots.imageData," : ""
        arguments += [query.limit + 1]
        return try Row.fetchAll(
            db,
            sql: """
            WITH candidates AS (
                SELECT
                    screenshots.id,
                    screenshots.capturedAt,
                    screenshots.mimeType,
                    \(imageDataSelection)
                    \(Self.elapsedSecondsSQL(timestampColumn: "screenshots.capturedAt")) AS elapsedSeconds
                FROM screenshots
                JOIN meetings ON meetings.id = screenshots.meetingId
                LEFT JOIN recording_sessions AS sessions
                  ON sessions.id = screenshots.sessionId
                 AND sessions.meetingId = screenshots.meetingId
                WHERE screenshots.meetingId = ? AND meetings.vaultId = ?
            )
            SELECT * FROM candidates
            \(filtering)
            ORDER BY elapsedSeconds ASC, id ASC
            LIMIT ?
            """,
            arguments: arguments
        )
    }

    private func screenshotImageRows(meetingID: UUID, screenshotIDs: [UUID], in db: Database) throws -> [Row] {
        let placeholders = Array(repeating: "?", count: screenshotIDs.count).joined(separator: ", ")
        var arguments: StatementArguments = [meetingID, vaultID]
        arguments += StatementArguments(screenshotIDs)
        return try Row.fetchAll(
            db,
            sql: """
            SELECT
                screenshots.id,
                screenshots.capturedAt,
                screenshots.mimeType,
                screenshots.imageData,
                \(Self.elapsedSecondsSQL(timestampColumn: "screenshots.capturedAt")) AS elapsedSeconds
            FROM screenshots
            JOIN meetings ON meetings.id = screenshots.meetingId
            LEFT JOIN recording_sessions AS sessions
              ON sessions.id = screenshots.sessionId
             AND sessions.meetingId = screenshots.meetingId
            WHERE screenshots.meetingId = ? AND meetings.vaultId = ?
              AND screenshots.id IN (\(placeholders))
            """,
            arguments: arguments
        )
    }

    private static func screenshotMetadata(from row: Row, referencedIDs: Set<UUID>) -> MeetingScreenshotMetadata {
        let capturedAt: Date = row["capturedAt"]
        let elapsed: Double = row["elapsedSeconds"]
        let id: UUID = row["id"]
        return MeetingScreenshotMetadata(
            id: id,
            capturedAt: capturedAt,
            elapsedSeconds: elapsed,
            timestamp: timestamp(elapsedSeconds: elapsed),
            mimeType: row["mimeType"],
            isReferencedInSummary: referencedIDs.contains(id)
        )
    }

    private func referencedScreenshotIDs(meetingID: UUID, in db: Database) throws -> Set<UUID> {
        guard let document = try String.fetchOne(
            db,
            sql: "SELECT document FROM summaries WHERE meetingId = ?",
            arguments: [meetingID]
        ), let data = document.data(using: .utf8),
        let root = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        var ids: Set<UUID> = []
        Self.collectScreenshotIDs(in: root, into: &ids)
        return ids
    }

    private static func collectScreenshotIDs(in value: Any, into ids: inout Set<UUID>) {
        if let object = value as? [String: Any] {
            if let value = object["screenshot_id"] as? String, let id = UUID(uuidString: value) {
                ids.insert(id)
            }
            for child in object.values {
                collectScreenshotIDs(in: child, into: &ids)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectScreenshotIDs(in: child, into: &ids)
            }
        }
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

private struct ScreenshotPayload {
    let metadata: MeetingScreenshotMetadata
    let imageData: Data
}

private struct ScreenshotPageData {
    let page: MeetingScreenshotPage
    let payloads: [ScreenshotPayload]
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
    let elapsedSeconds: Double
    let segmentID: UUID
    let fromElapsedSeconds: Double?
    let toElapsedSeconds: Double?

    func encoded() -> String {
        (try? JSONEncoder().encode(self).base64EncodedString()) ?? ""
    }

    static func decode(
        _ value: String,
        vaultID: UUID,
        meetingID: UUID,
        fromElapsedSeconds: Double?,
        toElapsedSeconds: Double?
    ) throws -> Self {
        guard let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(Self.self, from: data),
              cursor.vaultID == vaultID,
              cursor.meetingID == meetingID,
              cursor.fromElapsedSeconds == fromElapsedSeconds,
              cursor.toElapsedSeconds == toElapsedSeconds else {
            throw MeetingAccessError.invalidCursor
        }
        return cursor
    }
}

private struct ScreenshotCursor: Codable {
    let vaultID: UUID
    let meetingID: UUID
    let elapsedSeconds: Double
    let screenshotID: UUID
    let fromElapsedSeconds: Double?
    let toElapsedSeconds: Double?

    func encoded() -> String {
        (try? JSONEncoder().encode(self).base64EncodedString()) ?? ""
    }

    static func decode(
        _ value: String,
        vaultID: UUID,
        meetingID: UUID,
        fromElapsedSeconds: Double?,
        toElapsedSeconds: Double?
    ) throws -> Self {
        guard let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(Self.self, from: data),
              cursor.vaultID == vaultID,
              cursor.meetingID == meetingID,
              cursor.fromElapsedSeconds == fromElapsedSeconds,
              cursor.toElapsedSeconds == toElapsedSeconds else {
            throw MeetingAccessError.invalidCursor
        }
        return cursor
    }
}
