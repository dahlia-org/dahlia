import CryptoKit
import DahliaRuntimeSupport
import Foundation
import GRDB
import GRDBSQLite

public final class MeetingAccessStore: Sendable {
    private static let maximumSearchQueryLength = 1024

    public static var defaultDatabaseURL: URL {
        DahliaApplicationSupport.currentDirectoryURL
            .appending(path: "dahlia.sqlite")
    }

    let database: DatabaseQueue
    public let vaultID: UUID
    public let allowsWrites: Bool
    private let screenshotCache: ScreenshotFileStore?
    private let imageResolver: @Sendable (UUID, UUID, UUID) throws -> Data

    public init(
        databaseURL: URL = MeetingAccessStore.defaultDatabaseURL,
        vaultID: UUID,
        allowsWrites: Bool = false,
        screenshotCache: ScreenshotFileStore? = nil,
        imageResolver: (@Sendable (UUID, UUID, UUID) throws -> Data)? = nil
    ) throws {
        var configuration = Configuration()
        configuration.readonly = !allowsWrites
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try SearchFTS5Tokenizer.register(in: db)
        }
        database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        self.vaultID = vaultID
        self.allowsWrites = allowsWrites
        let usesAppDatabase = databaseURL.standardizedFileURL == Self.defaultDatabaseURL.standardizedFileURL
        self.screenshotCache = screenshotCache ?? (usesAppDatabase ? try? ScreenshotFileStore(readOnly: true) : nil)
        self.imageResolver = imageResolver ?? { vaultId, meetingId, screenshotId in
            guard usesAppDatabase else { throw MeetingAccessError.screenshotUnavailable }
            do {
                return try DahliaImageBrokerProtocol.requestImage(.init(vaultId: vaultId, meetingId: meetingId, screenshotId: screenshotId))
            } catch { throw MeetingAccessError.screenshotUnavailable }
        }
    }

    public func scopedVault() throws -> ScopedVault {
        try database.read(fetchVault(in:))
    }

    public func queryMeetings(_ query: MeetingQuery = MeetingQuery()) throws -> MeetingQueryPage {
        guard (1 ... 100).contains(query.limit) else {
            throw MeetingAccessError.invalidLimit(maximum: 100)
        }
        if let queryText = query.query, !queryText.dropFirst(Self.maximumSearchQueryLength).isEmpty {
            throw MeetingAccessError.invalidSearchQuery(maximum: Self.maximumSearchQueryLength)
        }

        return try database.read { db in
            let vault = try fetchVault(in: db)
            let usesTextSearch = query.query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            return try withSearchDeadline(enabled: usesTextSearch, in: db) {
                let usesFullTextSearch = usesTextSearch && !query.simple
                let indexRevision = try usesFullTextSearch ? fullTextIndexRevision(in: db) : nil
                let cursorScope = meetingCursorScope(query)
                let cursor = try query.cursor.map {
                    try MeetingCursor.decode($0, vaultID: vaultID, scope: cursorScope, indexRevision: indexRevision)
                }
                let queryComponents = try meetingQueryComponents(query, cursor: cursor, in: db)
                let rows = try meetingRows(in: db, components: queryComponents)
                let hasMore = rows.count > query.limit
                let pageRows = hasMore ? Array(rows.prefix(query.limit)) : rows
                let meetings = pageRows.map(Self.metadata(from:))
                let nextCursor = hasMore ? meetings.last.map {
                    MeetingCursor(
                        vaultID: vaultID,
                        scope: cursorScope,
                        indexRevision: indexRevision,
                        createdAt: $0.createdAt,
                        meetingID: $0.id
                    ).encoded()
                } : nil
                return MeetingQueryPage(vault: vault, meetings: meetings, nextCursor: nextCursor)
            }
        }
    }

    public func queryScreenshots(_ query: ScreenshotTextQuery) throws -> ScreenshotTextQueryPage {
        guard (1 ... 100).contains(query.limit) else {
            throw MeetingAccessError.invalidLimit(maximum: 100)
        }
        let text = query.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            throw MeetingAccessError.searchQueryTooShort(minimum: 2)
        }
        guard text.count <= Self.maximumSearchQueryLength else {
            throw MeetingAccessError.invalidSearchQuery(maximum: Self.maximumSearchQueryLength)
        }
        return try database.read { db in
            let vault = try fetchVault(in: db)
            return try withSearchDeadline(enabled: true, in: db) {
                let revision = try fullTextIndexRevision(in: db)
                let scope = screenshotCursorScope(text: text, query: query)
                let cursor = try query.cursor.map {
                    try ScreenshotTextCursor.decode($0, vaultID: vaultID, revision: revision, scope: scope)
                }
                guard let fullTextQuery = try fullTextQuery(text, in: db) else {
                    return ScreenshotTextQueryPage(vault: vault, screenshots: [], nextCursor: nil)
                }
                var conditions = [
                    "search_documents.kind = 'screenshot'",
                    "search_documents.vaultId = ?",
                    "search_documents_fts MATCH ?",
                ]
                var arguments: StatementArguments = [vaultID, "{ocr caption} : (\(fullTextQuery))"]
                if let projectID = query.projectID {
                    conditions.append("meetings.projectId = ?")
                    arguments += [projectID]
                }
                if let createdFrom = query.createdFrom {
                    conditions.append("meeting_images.capturedAt >= ?")
                    arguments += [createdFrom]
                }
                if let createdBefore = query.createdBefore {
                    conditions.append("meeting_images.capturedAt < ?")
                    arguments += [createdBefore]
                }
                arguments += [query.limit + 1, cursor?.offset ?? 0]
                var rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT meeting_images.id, meeting_images.meetingId, meetings.name AS meetingName,
                           meeting_images.capturedAt, meeting_images.mimeType,
                           meeting_images.ocrText AS detectedText, meeting_images.caption
                    FROM search_documents
                    JOIN search_documents_fts ON search_documents_fts.rowid = search_documents.id
                    JOIN meeting_images ON meeting_images.id = search_documents.sourceId
                    JOIN meetings ON meetings.id = meeting_images.meetingId
                    WHERE \(conditions.joined(separator: " AND "))
                    ORDER BY \(SearchFTS5Tokenizer.screenshotRankingSQL), meeting_images.capturedAt DESC, meeting_images.id
                    LIMIT ? OFFSET ?
                    """,
                    arguments: arguments
                )
                let hasMore = rows.count > query.limit
                if hasMore { rows.removeLast() }
                let screenshots = rows.map { row in
                    ScreenshotTextMetadata(
                        id: row["id"],
                        meetingID: row["meetingId"],
                        meetingName: row["meetingName"],
                        capturedAt: row["capturedAt"],
                        mimeType: row["mimeType"],
                        detectedText: String((row["detectedText"] as String).prefix(500)),
                        caption: row["caption"]
                    )
                }
                let nextCursor = hasMore
                    ? ScreenshotTextCursor(
                        vaultID: vaultID,
                        revision: revision,
                        scope: scope,
                        offset: (cursor?.offset ?? 0) + screenshots.count
                    ).encoded()
                    : nil
                return ScreenshotTextQueryPage(vault: vault, screenshots: screenshots, nextCursor: nextCursor)
            }
        }
    }

    private func fullTextIndexRevision(in db: Database) throws -> Int {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT phase, indexRevision FROM search_index_state WHERE indexKind = 'fts'"
        ) else {
            throw MeetingAccessError.searchUnavailable
        }
        let phase: String = row["phase"]
        guard phase == "ready" else { throw MeetingAccessError.searchUnavailable }
        return row["indexRevision"]
    }

    private func withSearchDeadline<Result>(
        enabled: Bool,
        in db: Database,
        _ operation: () throws -> Result
    ) throws -> Result {
        guard enabled else { return try operation() }
        let deadline = SearchDeadline()
        sqlite3_progress_handler(
            db.sqliteConnection,
            1000,
            { context in
                guard let context else { return 0 }
                let deadline = Unmanaged<SearchDeadline>.fromOpaque(context).takeUnretainedValue()
                return deadline.hasExpired ? 1 : 0
            },
            Unmanaged.passUnretained(deadline).toOpaque()
        )
        defer { sqlite3_progress_handler(db.sqliteConnection, 0, nil, nil) }
        do {
            return try withExtendedLifetime(deadline, operation)
        } catch DatabaseError.SQLITE_INTERRUPT {
            throw MeetingAccessError.searchTimedOut
        }
    }

    private func meetingQueryComponents(_ query: MeetingQuery, cursor: MeetingCursor?, in db: Database) throws -> QueryComponents {
        var components = QueryComponents(predicates: ["meetings.vaultId = ?"], arguments: [vaultID])
        let trimmedQuery = query.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedQuery, !trimmedQuery.isEmpty {
            if query.simple {
                components.appendSimpleSearch(pattern: "%\(escapedLikePattern(trimmedQuery))%")
            } else if let fullTextQuery = try fullTextQuery(trimmedQuery, in: db) {
                components.appendFullTextSearch(query: fullTextQuery)
            } else {
                components.predicates.append("0")
            }
        }
        let trimmedProject = query.project?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedProject, !trimmedProject.isEmpty {
            components.predicates.append("projects.name = ? COLLATE NOCASE")
            components.arguments += [trimmedProject]
        }
        if let projectID = query.projectID {
            components.predicates.append("projects.id = ?")
            components.arguments += [projectID]
        }
        if let organizationID = query.organizationID {
            if query.includeOrganizationDescendants {
                components.predicates.append("""
                EXISTS (
                    SELECT 1
                    FROM meeting_participants AS organization_participants
                    JOIN organization_memberships AS organization_memberships
                      ON organization_memberships.contactId = organization_participants.contactId
                    WHERE organization_participants.meetingId = meetings.id
                      AND organization_memberships.organizationId IN (
                          WITH RECURSIVE subtree(id, depth) AS (
                              SELECT id, 0 FROM organizations WHERE id = ? AND vaultId = ?
                              UNION ALL
                              SELECT child.id, subtree.depth + 1
                              FROM organizations AS child
                              JOIN subtree ON child.parentOrganizationId = subtree.id
                              WHERE child.vaultId = ? AND subtree.depth < 32
                          )
                          SELECT id FROM subtree
                      )
                )
                """)
                components.arguments += [organizationID, vaultID, vaultID]
            } else {
                components.predicates.append("""
                EXISTS (
                    SELECT 1
                    FROM meeting_participants AS organization_participants
                    JOIN organization_memberships AS organization_memberships
                      ON organization_memberships.contactId = organization_participants.contactId
                    WHERE organization_participants.meetingId = meetings.id
                      AND organization_memberships.organizationId = ?
                )
                """)
                components.arguments += [organizationID]
            }
        }
        if let topicID = query.topicID {
            components.predicates.append("""
            EXISTS (
                SELECT 1 FROM conversation_topic_references
                JOIN conversation_topics
                  ON conversation_topics.id = conversation_topic_references.topicId
                WHERE conversation_topic_references.resourceType = 'meeting'
                  AND conversation_topic_references.resourceId = meetings.id
                  AND conversation_topics.id = ?
                  AND conversation_topics.vaultId = meetings.vaultId
            )
            """)
            components.arguments += [topicID]
        }
        let trimmedIcalUID = query.icalUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedIcalUID, !trimmedIcalUID.isEmpty {
            components.predicates.append("meetings.calendar_event_ical_uid = ?")
            components.arguments += [trimmedIcalUID]
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

    private func meetingCursorScope(_ query: MeetingQuery) -> String {
        let components = MeetingCursorFilterScope(
            query: query.query?.trimmingCharacters(in: .whitespacesAndNewlines),
            simple: query.simple,
            project: query.project?.trimmingCharacters(in: .whitespacesAndNewlines),
            projectID: query.projectID,
            organizationID: query.organizationID,
            includesOrganizationDescendants: query.includeOrganizationDescendants,
            topicID: query.topicID,
            icalUID: query.icalUID?.trimmingCharacters(in: .whitespacesAndNewlines),
            createdFrom: query.createdFrom,
            createdBefore: query.createdBefore
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(components) else { return "meetings" }
        return data.base64EncodedString()
    }

    private func screenshotCursorScope(text: String, query: ScreenshotTextQuery) -> String {
        let components = ScreenshotTextCursorFilterScope(
            query: text,
            projectID: query.projectID,
            createdFrom: query.createdFrom,
            createdBefore: query.createdBefore
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(components) else { return "screenshots" }
        return data.base64EncodedString()
    }

    private func fullTextQuery(_ value: String, in db: Database) throws -> String? {
        let tokens = try SearchFTS5Tokenizer.queryTokens(for: value, in: db)
        guard !tokens.isEmpty else { return nil }
        return tokens.enumerated().map { index, token in
            SearchFTS5Tokenizer.quotedQueryToken(token, isPrefix: index == tokens.count - 1)
        }.joined(separator: " AND ")
    }

    private func meetingRows(in db: Database, components: QueryComponents) throws -> [Row] {
        var arguments: StatementArguments = [vaultID, vaultID]
        arguments += components.arguments
        return try Row.fetchAll(
            db,
            sql: """
            WITH RECURSIVE project_paths(id, vaultId, name) AS (
                SELECT id, vaultId, name
                FROM projects
                WHERE parentProjectId IS NULL AND vaultId = ?
                UNION ALL
                SELECT child.id, child.vaultId, project_paths.name || '/' || child.name
                FROM projects AS child
                JOIN project_paths ON project_paths.id = child.parentProjectId
                WHERE child.vaultId = ?
            )
            SELECT
                meetings.id,
                meetings.name,
                meetings.description,
                projects.name AS project,
                projects.id AS projectId,
                meetings.calendar_event_ical_uid AS icalUid,
                meetings.calendar_event_recurrence_id AS recurrenceId,
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
            LEFT JOIN project_paths AS projects
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
            arguments: arguments
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
                    summaryDocument = try StoredSummaryDocumentMarkdownRenderer.toolJSONValue(decoded)
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
                summaryDocument: summaryDocument,
                summaryDocumentVersion: document.map(Self.summaryDocumentVersion)
            )
        }
    }

    /// 保存済みドキュメント文字列そのものから導く版。`summaries` に revision 列がないため、
    /// これを `update_meeting_summary` の compare-and-swap に使う。
    /// 書き手が採番を忘れる余地がなく、マイグレーションも不要。
    static func summaryDocumentVersion(_ storedDocument: String) -> String {
        SHA256.hash(data: Data(storedDocument.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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

private struct MeetingCursorFilterScope: Codable {
    let query: String?
    let simple: Bool
    let project: String?
    let projectID: UUID?
    let organizationID: UUID?
    let includesOrganizationDescendants: Bool
    let topicID: UUID?
    let icalUID: String?
    let createdFrom: Date?
    let createdBefore: Date?
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
        query: ScreenshotQuery,
        originalSize: Bool = false
    ) throws -> (page: MeetingScreenshotPage, images: [MeetingScreenshotImage]) {
        let result = try screenshotPageData(meetingID: meetingID, query: query, includeImageData: true)
        let images = try result.payloads.map { try encodedScreenshot($0, meetingID: meetingID, originalSize: originalSize) }
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
                ScreenshotPayload(fileId: $0.0["fileId"], metadata: $0.1, imageData: $0.0["imageData"], remoteReference: $0.0["remoteReference"])
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

    public func screenshot(
        meetingID: UUID,
        screenshotID: UUID,
        originalSize: Bool = false
    ) throws -> MeetingScreenshotImage {
        guard let image = try screenshotImages(
            meetingID: meetingID,
            screenshotIDs: [screenshotID],
            originalSize: originalSize
        ).first else {
            throw MeetingAccessError.screenshotNotFound
        }
        return image
    }

    public func screenshotImages(
        meetingID: UUID,
        screenshotIDs: [UUID],
        originalSize: Bool = false
    ) throws -> [MeetingScreenshotImage] {
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
                return (
                    metadata.id,
                    ScreenshotPayload(fileId: row["fileId"], metadata: metadata, imageData: row["imageData"], remoteReference: row["remoteReference"])
                )
            })
            return try screenshotIDs.map { id in
                guard let payload = payloadsByID[id] else { throw MeetingAccessError.screenshotNotFound }
                return payload
            }
        }
        return try payloads.map { payload in
            try encodedScreenshot(payload, meetingID: meetingID, originalSize: originalSize)
        }
    }

    private func encodedScreenshot(
        _ payload: ScreenshotPayload,
        meetingID: UUID,
        originalSize: Bool
    ) throws -> MeetingScreenshotImage {
        var original = payload.imageData
        if original == nil, let json = payload.remoteReference,
           let source = try? JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(json.utf8)),
           source.fileId == payload.fileId {
            original = try? screenshotCache?.read(source, variant: .original)?.data
        }
        if original == nil {
            original = try imageResolver(vaultID, meetingID, payload.metadata.id)
        }
        guard let original else { throw MeetingAccessError.screenshotUnavailable }
        let imageData = originalSize
            ? original
            : ImageEncoder.resizedIfPossible(original, maxLongEdge: ImageEncoder.aiInputMaximumLongEdge)
        guard let imageData,
              let mimeType = ImageEncoder.mimeType(for: imageData) else {
            throw MeetingAccessError.screenshotEncodingFailed
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
        let columns = try db.columns(in: "meeting_images").map(\.name)
        let remoteSelection = columns.contains("localReference")
            ? "coalesce(meeting_images.localReference, meeting_images.remoteReference) AS remoteReference"
            : columns.contains("remoteReference") ? "meeting_images.remoteReference" : "NULL AS remoteReference"
        let imageDataSelection = includeImageData ? "meeting_images.fileId, meeting_images.imageData, \(remoteSelection)," : ""
        arguments += [query.limit + 1]
        return try Row.fetchAll(
            db,
            sql: """
            WITH candidates AS (
                SELECT
                    meeting_images.id,
                    meeting_images.capturedAt,
                    meeting_images.mimeType,
                    \(imageDataSelection)
                    \(Self.elapsedSecondsSQL(timestampColumn: "meeting_images.capturedAt")) AS elapsedSeconds
                FROM meeting_images
                JOIN meetings ON meetings.id = meeting_images.meetingId
                LEFT JOIN recording_sessions AS sessions
                  ON sessions.id = meeting_images.sessionId
                 AND sessions.meetingId = meeting_images.meetingId
                WHERE meeting_images.meetingId = ? AND meetings.vaultId = ?
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
        let columns = try db.columns(in: "meeting_images").map(\.name)
        let remoteSelection = columns.contains("localReference")
            ? "coalesce(meeting_images.localReference, meeting_images.remoteReference) AS remoteReference"
            : columns.contains("remoteReference") ? "meeting_images.remoteReference" : "NULL AS remoteReference"
        let placeholders = Array(repeating: "?", count: screenshotIDs.count).joined(separator: ", ")
        var arguments: StatementArguments = [meetingID, vaultID]
        arguments += StatementArguments(screenshotIDs)
        return try Row.fetchAll(
            db,
            sql: """
            SELECT
                meeting_images.id,
                meeting_images.capturedAt,
                meeting_images.mimeType,
                meeting_images.fileId,
                meeting_images.imageData,
                \(remoteSelection),
                \(Self.elapsedSecondsSQL(timestampColumn: "meeting_images.capturedAt")) AS elapsedSeconds
            FROM meeting_images
            JOIN meetings ON meetings.id = meeting_images.meetingId
            LEFT JOIN recording_sessions AS sessions
              ON sessions.id = meeting_images.sessionId
             AND sessions.meetingId = meeting_images.meetingId
            WHERE meeting_images.meetingId = ? AND meetings.vaultId = ?
              AND meeting_images.id IN (\(placeholders))
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

    func fetchVault(in db: Database) throws -> ScopedVault {
        let meetingColumns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('meetings')")
        let summaryColumns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('summaries')"))
        let searchColumns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('search_documents_fts')"))
        let projectColumns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('projects')"))
        let legacySummaryColumns: Set = ["summary", "googleFileId", "vaultRelativePath"]
        guard meetingColumns.contains("description"),
              summaryColumns.contains("document"),
              searchColumns.isSuperset(of: ["summary", "ocr", "caption"]),
              summaryColumns.isDisjoint(with: legacySummaryColumns),
              projectColumns.isSuperset(of: ["parentProjectId", "name", "nameKey", "projectType", "revision"]),
              try Bool.fetchOne(
                  db,
                  sql: """
                  SELECT COUNT(*) = 3 FROM sqlite_master
                  WHERE type = 'table'
                    AND name IN ('search_documents', 'search_documents_fts', 'search_index_state')
                  """
              ) == true
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
            WITH RECURSIVE project_paths(id, vaultId, name) AS (
                SELECT id, vaultId, name
                FROM projects
                WHERE parentProjectId IS NULL AND vaultId = ?
                UNION ALL
                SELECT child.id, child.vaultId, project_paths.name || '/' || child.name
                FROM projects AS child
                JOIN project_paths ON project_paths.id = child.parentProjectId
                WHERE child.vaultId = ?
            )
            SELECT
                meetings.id,
                meetings.name,
                meetings.description,
                projects.name AS project,
                projects.id AS projectId,
                meetings.calendar_event_ical_uid AS icalUid,
                meetings.calendar_event_recurrence_id AS recurrenceId,
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
            LEFT JOIN project_paths AS projects
              ON projects.id = meetings.projectId
             AND projects.vaultId = meetings.vaultId
            LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            LEFT JOIN summaries ON summaries.meetingId = meetings.id
            WHERE meetings.id = ? AND meetings.vaultId = ?
            """,
            arguments: [vaultID, vaultID, id, vaultID]
        )
    }

    private static func metadata(from row: Row) -> MeetingMetadata {
        let tagString: String? = row["tags"]
        return MeetingMetadata(
            id: row["id"],
            name: row["name"],
            description: row["description"],
            project: row["project"],
            projectID: row["projectId"],
            icalUID: row["icalUid"],
            recurrenceID: row["recurrenceId"],
            calendarTitle: row["calendarTitle"],
            status: row["status"],
            durationSeconds: row["duration"],
            createdAt: row["createdAt"],
            hasSummary: row["hasSummary"],
            transcriptSegmentCount: row["transcriptSegmentCount"],
            tags: tagString?.split(separator: "\u{1F}").map(String.init) ?? []
        )
    }

    func escapedLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

private struct ScreenshotPayload {
    let fileId: UUID
    let metadata: MeetingScreenshotMetadata
    let imageData: Data?
    let remoteReference: String?
}

private struct ScreenshotPageData {
    let page: MeetingScreenshotPage
    let payloads: [ScreenshotPayload]
}

private struct QueryComponents {
    var predicates: [String]
    var arguments: StatementArguments

    mutating func appendSimpleSearch(pattern: String) {
        predicates.append("""
        (
            meetings.name LIKE ? ESCAPE '\\' COLLATE NOCASE
            OR meetings.description LIKE ? ESCAPE '\\' COLLATE NOCASE
            OR calendar_events.title LIKE ? ESCAPE '\\' COLLATE NOCASE
            OR EXISTS (
                SELECT 1 FROM meeting_tags
                JOIN tags ON tags.id = meeting_tags.tagId
                WHERE meeting_tags.meetingId = meetings.id
                  AND tags.name LIKE ? ESCAPE '\\' COLLATE NOCASE
            )
        )
        """)
        for _ in 0 ..< 4 {
            arguments += [pattern]
        }
    }

    mutating func appendFullTextSearch(query: String) {
        predicates.append("""
        EXISTS (
            SELECT 1
            FROM search_documents
            JOIN search_documents_fts ON search_documents_fts.rowid = search_documents.id
            WHERE search_documents.kind = 'meeting'
              AND search_documents.meetingId = meetings.id
              AND search_documents.vaultId = meetings.vaultId
              AND search_documents_fts MATCH ?
        )
        """)
        arguments += ["{title description summary calendar tags} : (\(query))"]
    }
}

private struct MeetingCursor: Codable {
    let vaultID: UUID
    let scope: String
    let indexRevision: Int?
    let createdAt: Date
    let meetingID: UUID

    func encoded() -> String {
        AccessCursorCodec.encode(self)
    }

    static func decode(_ value: String, vaultID: UUID, scope: String, indexRevision: Int?) throws -> Self {
        try AccessCursorCodec.decode(Self.self, from: value) { cursor in
            cursor.vaultID == vaultID && cursor.scope == scope && cursor.indexRevision == indexRevision
        }
    }
}

private final class SearchDeadline {
    private let deadline = ContinuousClock.now + .seconds(30)
    var hasExpired: Bool { ContinuousClock.now >= deadline }
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
        AccessCursorCodec.encode(self)
    }

    static func decode(
        _ value: String,
        vaultID: UUID,
        meetingID: UUID,
        fromElapsedSeconds: Double?,
        toElapsedSeconds: Double?
    ) throws -> Self {
        try AccessCursorCodec.decode(Self.self, from: value) { cursor in
            cursor.vaultID == vaultID
                && cursor.meetingID == meetingID
                && cursor.fromElapsedSeconds == fromElapsedSeconds
                && cursor.toElapsedSeconds == toElapsedSeconds
        }
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
        AccessCursorCodec.encode(self)
    }

    static func decode(
        _ value: String,
        vaultID: UUID,
        meetingID: UUID,
        fromElapsedSeconds: Double?,
        toElapsedSeconds: Double?
    ) throws -> Self {
        try AccessCursorCodec.decode(Self.self, from: value) { cursor in
            cursor.vaultID == vaultID
                && cursor.meetingID == meetingID
                && cursor.fromElapsedSeconds == fromElapsedSeconds
                && cursor.toElapsedSeconds == toElapsedSeconds
        }
    }
}

private struct ScreenshotTextCursor: Codable {
    let vaultID: UUID
    let revision: Int
    let scope: String
    let offset: Int

    func encoded() -> String { AccessCursorCodec.encode(self) }

    static func decode(_ value: String, vaultID: UUID, revision: Int, scope: String) throws -> Self {
        try AccessCursorCodec.decode(Self.self, from: value) {
            $0.vaultID == vaultID && $0.revision == revision && $0.scope == scope && $0.offset >= 0
        }
    }
}

private struct ScreenshotTextCursorFilterScope: Codable {
    let query: String
    let projectID: UUID?
    let createdFrom: Date?
    let createdBefore: Date?
}
