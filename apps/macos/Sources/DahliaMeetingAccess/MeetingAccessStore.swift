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

    let database: any DatabaseWriter
    public let workspaceID: UUID
    public let allowsWrites: Bool
    let accountScope: MCPAccountScope?
    private let screenshotCache: ScreenshotFileStore?
    private let imageResolver: @Sendable (UUID, UUID, UUID) throws -> Data
    let textResolver: (@Sendable (UUID, TextBrokerRequest) throws -> Data)?

    public init(
        databaseURL: URL = MeetingAccessStore.defaultDatabaseURL,
        workspaceID: UUID,
        allowsWrites: Bool = false,
        accountScope: MCPAccountScope? = nil,
        screenshotCache: ScreenshotFileStore? = nil,
        imageResolver: (@Sendable (UUID, UUID, UUID) throws -> Data)? = nil,
        textResolver: (@Sendable (UUID, TextBrokerRequest) throws -> Data)? = nil
    ) throws {
        var configuration = Configuration()
        configuration.readonly = !allowsWrites
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try SearchFTS5Tokenizer.register(in: db)
        }
        database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        self.workspaceID = workspaceID
        self.allowsWrites = allowsWrites
        self.accountScope = accountScope
        let usesAppDatabase = databaseURL.standardizedFileURL == Self.defaultDatabaseURL.standardizedFileURL
        self.textResolver = textResolver ?? (usesAppDatabase ? { @Sendable workspaceId, request in
            try DahliaImageBrokerProtocol.requestImage(.init(workspaceId: workspaceId, text: request))
        } : nil)
        self.screenshotCache = screenshotCache ?? (usesAppDatabase ? try? ScreenshotFileStore(readOnly: true) : nil)
        self.imageResolver = imageResolver ?? { workspaceId, meetingId, screenshotId in
            guard usesAppDatabase else { throw MeetingAccessError.screenshotUnavailable }
            do {
                return try DahliaImageBrokerProtocol.requestImage(.init(workspaceId: workspaceId, meetingId: meetingId, screenshotId: screenshotId))
            } catch { throw MeetingAccessError.screenshotUnavailable }
        }
    }

    /// App-side broker reads use the same scoped SQL without recursively entering IPC.
    public init(database: any DatabaseWriter, workspaceID: UUID) {
        self.database = database
        self.workspaceID = workspaceID
        allowsWrites = false
        accountScope = nil
        screenshotCache = nil
        imageResolver = { _, _, _ in throw MeetingAccessError.screenshotUnavailable }
        textResolver = nil
    }

    func scoped(to workspaceID: UUID) -> MeetingAccessStore {
        MeetingAccessStore(copying: self, workspaceID: workspaceID)
    }

    private init(copying store: MeetingAccessStore, workspaceID: UUID) {
        database = store.database
        self.workspaceID = workspaceID
        allowsWrites = store.allowsWrites
        accountScope = store.accountScope
        screenshotCache = store.screenshotCache
        imageResolver = store.imageResolver
        textResolver = store.textResolver
    }

    private func remoteSearch(
        query: String,
        kind: TextSearchKind,
        cursor: String?,
        scope: String,
        limit: Int,
        filter: ([TextSearchPage.Item], Database) throws -> [TextSearchPage.Item]
    ) -> RemoteTextSearchResults? {
        let isServer = (try? database.read { db in
            try Bool.fetchOne(db, sql: "SELECT accountConnectionId IS NOT NULL FROM workspaces WHERE id = ?", arguments: [workspaceID]) == true
        }) == true
        guard isServer else { return nil }
        do {
            guard let textResolver else { throw TextContentError.unavailable }
            var position = try cursor.map { try AccessCursorCodec.decode(ServerSearchCursor.self, from: $0) { $0.scope == scope }.position }
            repeat {
                let page = try JSONDecoder().decode(
                    TextSearchPage.self,
                    from: textResolver(workspaceID, .init(operation: .search, query: query, kind: kind, cursor: position, limit: limit))
                )
                let items = try database.read { db in
                    _ = try fetchWorkspace(in: db)
                    guard !page.items.isEmpty else { return [TextSearchPage.Item]() }
                    let ids = Array(Set(page.items.map(\.meetingId)))
                    let known = try Int.fetchOne(
                        db,
                        sql: "SELECT count(*) FROM meetings WHERE workspace_id = ? AND id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))",
                        arguments: StatementArguments([workspaceID] + ids)
                    )
                    guard known == ids.count else { throw TextContentError.changed }
                    return try filter(page.items, db)
                }
                position = page.nextCursor
                if !items.isEmpty || position == nil {
                    return RemoteTextSearchResults(
                        items: items,
                        nextCursor: position.map { AccessCursorCodec.encode(ServerSearchCursor(scope: scope, position: $0)) },
                        complete: position == nil
                    )
                }
            } while true
        } catch {
            return RemoteTextSearchResults(
                items: [],
                nextCursor: cursor,
                complete: false,
                error: (error as? TextContentError)?.rawValue ?? "server_search_incomplete"
            )
        }
    }

    public func scopedWorkspace() throws -> ScopedWorkspace {
        try database.read(fetchWorkspace(in:))
    }

    public func queryMeetings(_ query: MeetingQuery = MeetingQuery()) throws -> MeetingQueryPage {
        var result = try cachedQueryMeetings(query)
        if query.query?.isEmpty == false {
            result.searchScope = query.simple ? "device_metadata" : "device_metadata_and_retained_text_including_tags_calendar"
            if !query.simple {
                result.server = remoteSearch(
                    query: query.query ?? "",
                    kind: .meeting,
                    cursor: query.serverCursor,
                    scope: meetingCursorScope(query),
                    limit: query.limit
                ) { hits, db in
                    var metadataQuery = query
                    metadataQuery.query = nil
                    metadataQuery.cursor = nil
                    metadataQuery.limit = 200
                    var components = try self.meetingQueryComponents(metadataQuery, cursor: nil, in: db)
                    components.predicates.append("meetings.id IN (\(Array(repeating: "?", count: hits.count).joined(separator: ",")))")
                    components.arguments += StatementArguments(hits.map(\.meetingId))
                    let allowed = try Set(self.meetingRows(in: db, components: components, limit: metadataQuery.limit).map { $0["id"] as UUID })
                    return hits.filter { allowed.contains($0.meetingId) }
                }
            }
        }
        return result
    }

    private func cachedQueryMeetings(_ query: MeetingQuery) throws -> MeetingQueryPage {
        guard (1 ... 100).contains(query.limit) else {
            throw MeetingAccessError.invalidLimit(maximum: 100)
        }
        if let queryText = query.query, !queryText.dropFirst(Self.maximumSearchQueryLength).isEmpty {
            throw MeetingAccessError.invalidSearchQuery(maximum: Self.maximumSearchQueryLength)
        }

        return try database.read { db in
            let workspace = try fetchWorkspace(in: db)
            let usesTextSearch = query.query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            return try withSearchDeadline(enabled: usesTextSearch, in: db) {
                let usesFullTextSearch = usesTextSearch && !query.simple
                let indexRevision = try usesFullTextSearch ? fullTextIndexRevision(in: db) : nil
                let cursorScope = meetingCursorScope(query)
                let cursor = try query.cursor.map {
                    try MeetingCursor.decode($0, workspaceID: workspaceID, scope: cursorScope, indexRevision: indexRevision)
                }
                let queryComponents = try meetingQueryComponents(query, cursor: cursor, in: db)
                let rows = try meetingRows(in: db, components: queryComponents, limit: query.limit)
                let hasMore = rows.count > query.limit
                let pageRows = hasMore ? Array(rows.prefix(query.limit)) : rows
                let meetings = pageRows.map(Self.metadata(from:))
                let nextCursor = hasMore ? meetings.last.map {
                    MeetingCursor(
                        workspaceID: workspaceID,
                        scope: cursorScope,
                        indexRevision: indexRevision,
                        createdAt: $0.createdAt,
                        meetingID: $0.id
                    ).encoded()
                } : nil
                return MeetingQueryPage(workspace: workspace, meetings: meetings, nextCursor: nextCursor)
            }
        }
    }

    public func queryScreenshots(_ query: ScreenshotTextQuery) throws -> ScreenshotTextQueryPage {
        var result = try cachedQueryScreenshots(query)
        guard let text = query.query else { return result }
        result.searchScope = "device_retained_text"
        result.server = remoteSearch(
            query: text,
            kind: .screenshot,
            cursor: query.serverCursor,
            scope: screenshotCursorScope(text: text, query: query),
            limit: query.limit
        ) { hits, db in
            try hits.filter { hit in
                guard let row = try Row.fetchOne(db, sql: """
                SELECT meetings.projectId, s.capturedAt,
                       \(Self.elapsedSecondsSQL(timestampColumn: "s.capturedAt")) AS elapsedSeconds
                FROM meeting_images s JOIN meetings ON meetings.id = s.meetingId
                LEFT JOIN recording_sessions AS sessions ON sessions.id = s.sessionId AND sessions.meetingId = s.meetingId
                WHERE s.id = ? AND meetings.id = ? AND meetings.workspace_id = ?
                """, arguments: [hit.id, hit.meetingId, self.workspaceID]) else { throw TextContentError.changed }
                let projectId: UUID? = row["projectId"]
                let date: Date = row["capturedAt"]
                let elapsed: Double = row["elapsedSeconds"]
                return (query.projectID == nil || query.projectID == projectId)
                    && (query.meetingID == nil || query.meetingID == hit.meetingId)
                    && (query.fromElapsedSeconds.map { elapsed >= $0 } ?? true)
                    && (query.toElapsedSeconds.map { elapsed < $0 } ?? true)
                    && (query.createdFrom == nil || date >= query.createdFrom!)
                    && (query.createdBefore == nil || date < query.createdBefore!)
            }
        }
        return result
    }

    // swiftlint:disable:next function_body_length
    private func cachedQueryScreenshots(_ query: ScreenshotTextQuery) throws -> ScreenshotTextQueryPage {
        guard (1 ... 100).contains(query.limit) else {
            throw MeetingAccessError.invalidLimit(maximum: 100)
        }
        let text = query.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text {
            guard text.count >= 2 else {
                throw MeetingAccessError.searchQueryTooShort(minimum: 2)
            }
            guard text.count <= Self.maximumSearchQueryLength else {
                throw MeetingAccessError.invalidSearchQuery(maximum: Self.maximumSearchQueryLength)
            }
        }
        try validateTimeRange(from: query.fromElapsedSeconds, to: query.toElapsedSeconds)
        return try database.read { db in
            let workspace = try fetchWorkspace(in: db)
            if let meetingID = query.meetingID, try !meetingExists(id: meetingID, in: db) {
                throw MeetingAccessError.meetingNotFound
            }
            return try withSearchDeadline(enabled: text != nil, in: db) {
                // A listing continues by capture position independently of full-text index rebuilds.
                let revision = try text == nil ? 0 : fullTextIndexRevision(in: db)
                let scope = screenshotCursorScope(text: text, query: query)
                let cursor = try query.cursor.map {
                    try ScreenshotTextCursor.decode($0, workspaceID: workspaceID, revision: revision, scope: scope)
                }
                let elapsedSQL = Self.elapsedSecondsSQL(timestampColumn: "meeting_images.capturedAt")
                var source = """
                FROM meeting_images
                JOIN meetings ON meetings.id = meeting_images.meetingId
                """
                var conditions = ["meetings.workspace_id = ?"]
                var arguments: StatementArguments = [workspaceID]
                var order = query.meetingID == nil
                    ? "meeting_images.capturedAt, meeting_images.id"
                    : "elapsedSeconds, meeting_images.id"
                var tokens: [String] = []
                if let text {
                    guard let fullTextQuery = try fullTextQuery(text, in: db) else {
                        return ScreenshotTextQueryPage(workspace: workspace, screenshots: [], nextCursor: nil)
                    }
                    tokens = try SearchFTS5Tokenizer.queryTokens(for: text, in: db)
                    source = """
                    FROM search_documents
                    JOIN search_documents_fts ON search_documents_fts.rowid = search_documents.id
                    JOIN meeting_images ON meeting_images.id = search_documents.sourceId
                    JOIN meetings ON meetings.id = meeting_images.meetingId
                    """
                    conditions += ["search_documents.kind = 'screenshot'", "search_documents.workspace_id = ?", "search_documents_fts MATCH ?"]
                    arguments += [workspaceID, "{ocr caption} : (\(fullTextQuery))"]
                    order = "\(SearchFTS5Tokenizer.screenshotRankingSQL), meeting_images.capturedAt DESC, meeting_images.id"
                }
                if let projectID = query.projectID {
                    conditions.append("meetings.projectId = ?")
                    arguments += [projectID]
                }
                if let meetingID = query.meetingID {
                    conditions.append("meeting_images.meetingId = ?")
                    arguments += [meetingID]
                }
                if let from = query.fromElapsedSeconds {
                    conditions.append("\(elapsedSQL) >= ?")
                    arguments += [from]
                }
                if let to = query.toElapsedSeconds {
                    conditions.append("\(elapsedSQL) < ?")
                    arguments += [to]
                }
                if let createdFrom = query.createdFrom {
                    conditions.append("meeting_images.capturedAt >= ?")
                    arguments += [createdFrom]
                }
                if let createdBefore = query.createdBefore {
                    conditions.append("meeting_images.capturedAt < ?")
                    arguments += [createdBefore]
                }
                if text == nil, let cursor {
                    guard let id = cursor.screenshotID, let capturedAt = cursor.capturedAt,
                          let elapsed = cursor.elapsedSeconds else { throw MeetingAccessError.invalidCursor }
                    if query.meetingID != nil {
                        conditions.append("(\(elapsedSQL), meeting_images.id) > (?, ?)")
                        arguments += [elapsed, id]
                    } else {
                        conditions.append("(meeting_images.capturedAt, meeting_images.id) > (?, ?)")
                        arguments += [capturedAt, id]
                    }
                }
                arguments += [query.limit + 1, text == nil ? 0 : cursor?.offset ?? 0]
                let referenceSelection = try Self.screenshotReferenceSelection(in: db)
                var rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT meeting_images.id, meeting_images.meetingId, meetings.name AS meetingName,
                           meeting_images.capturedAt, meeting_images.mimeType,
                           meeting_images.ocrText AS detectedText, meeting_images.caption,
                           meeting_images.fileId, \(referenceSelection), \(elapsedSQL) AS elapsedSeconds
                    \(source)
                    LEFT JOIN recording_sessions AS sessions
                      ON sessions.id = meeting_images.sessionId
                     AND sessions.meetingId = meeting_images.meetingId
                    WHERE \(conditions.joined(separator: " AND "))
                    ORDER BY \(order)
                    LIMIT ? OFFSET ?
                    """,
                    arguments: arguments
                )
                let hasMore = rows.count > query.limit
                if hasMore { rows.removeLast() }
                let screenshots = rows.map { row in
                    let elapsed: Double = row["elapsedSeconds"]
                    return ScreenshotTextMetadata(
                        id: row["id"],
                        meetingID: row["meetingId"],
                        meetingName: row["meetingName"],
                        capturedAt: row["capturedAt"],
                        elapsedSeconds: elapsed,
                        timestamp: Self.timestamp(elapsedSeconds: elapsed),
                        mimeType: row["mimeType"],
                        // Without query tokens this is the leading excerpt of the same length.
                        detectedText: (row["detectedText"] as String?).map { SearchFTS5Tokenizer.snippet($0, matching: tokens) },
                        caption: row["caption"],
                        filePath: originalFilePath(reference: row["remoteReference"], fileId: row["fileId"])
                    )
                }
                let last = text == nil ? screenshots.last : nil
                let nextCursor = hasMore
                    ? ScreenshotTextCursor(
                        workspaceID: workspaceID,
                        revision: revision,
                        scope: scope,
                        offset: text == nil ? 0 : (cursor?.offset ?? 0) + screenshots.count,
                        capturedAt: last?.capturedAt,
                        elapsedSeconds: last?.elapsedSeconds,
                        screenshotID: last?.id
                    ).encoded()
                    : nil
                return ScreenshotTextQueryPage(workspace: workspace, screenshots: screenshots, nextCursor: nextCursor)
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
        var components = QueryComponents(predicates: ["meetings.workspace_id = ?"], arguments: [workspaceID])
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
        let trimmedIcalUID = query.icalUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedIcalUID, !trimmedIcalUID.isEmpty {
            components.predicates.append("meetings.calendar_event_ical_uid = ?")
            components.arguments += [trimmedIcalUID]
        }
        let trimmedAttendee = query.attendee?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedAttendee, !trimmedAttendee.isEmpty {
            db.add(function: DatabaseFunction("dahlia_attendee_contains", argumentCount: 2, pure: true) { values in
                guard let text = String.fromDatabaseValue(values[0]),
                      let query = String.fromDatabaseValue(values[1]) else { return false }
                return text.range(of: query, options: .caseInsensitive) != nil
            })
            components.predicates.append("""
            EXISTS (
                SELECT 1 FROM json_each(
                    CASE WHEN meetings.calendarSyncMetadata IS NOT NULL
                         THEN json_extract(CAST(meetings.calendarSyncMetadata AS TEXT), '$.calendarEvent.attendees')
                         ELSE calendar_events.attendees_json END
                ) AS attendee
                WHERE dahlia_attendee_contains(attendee.value ->> 'email', ?)
                   OR dahlia_attendee_contains(attendee.value ->> 'display_name', ?)
            )
            """)
            components.arguments += [trimmedAttendee, trimmedAttendee]
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
        return components
    }

    private func meetingCursorScope(_ query: MeetingQuery) -> String {
        let components = MeetingCursorFilterScope(
            query: query.query?.trimmingCharacters(in: .whitespacesAndNewlines),
            simple: query.simple,
            project: query.project?.trimmingCharacters(in: .whitespacesAndNewlines),
            projectID: query.projectID,
            icalUID: query.icalUID?.trimmingCharacters(in: .whitespacesAndNewlines),
            attendee: query.attendee?.trimmingCharacters(in: .whitespacesAndNewlines),
            createdFrom: query.createdFrom,
            createdBefore: query.createdBefore
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(components) else { return "meetings" }
        return data.base64EncodedString()
    }

    private func screenshotCursorScope(text: String?, query: ScreenshotTextQuery) -> String {
        let components = ScreenshotTextCursorFilterScope(
            query: text,
            projectID: query.projectID,
            meetingID: query.meetingID,
            fromElapsedSeconds: query.fromElapsedSeconds,
            toElapsedSeconds: query.toElapsedSeconds,
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

    private func transcriptCountSQL(in db: Database) throws -> String {
        let local = "(SELECT COUNT(*) FROM transcript_segments WHERE transcript_segments.meetingId = meetings.id)"
        guard try db.tableExists("sync_content_state") else { return local }
        return "max(\(local), coalesce((SELECT contentCount FROM sync_content_state WHERE entity = 'transcript' AND entityId = meetings.id AND complete = 0), 0))"
    }

    private func meetingRows(in db: Database, components: QueryComponents, limit: Int) throws -> [Row] {
        var arguments: StatementArguments = [workspaceID, workspaceID]
        arguments += components.arguments
        arguments += [limit + 1]
        return try Row.fetchAll(
            db,
            sql: """
            WITH RECURSIVE project_paths(id, workspace_id, name) AS (
                SELECT id, workspace_id, name
                FROM projects
                WHERE parentProjectId IS NULL AND workspace_id = ?
                UNION ALL
                SELECT child.id, child.workspace_id, project_paths.name || '/' || child.name
                FROM projects AS child
                JOIN project_paths ON project_paths.id = child.parentProjectId
                WHERE child.workspace_id = ?
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
                EXISTS(SELECT 1 FROM recording_sessions rs WHERE rs.meetingId = meetings.id AND rs.endedAt IS NULL) AS isRecording,
                meetings.duration,
                meetings.createdAt,
                summaries.meetingId IS NOT NULL AS hasSummary,
                \(transcriptCountSQL(in: db)) AS transcriptSegmentCount,
                (SELECT GROUP_CONCAT(tags.name, char(31))
                 FROM meeting_tags JOIN tags ON tags.id = meeting_tags.tagId
                 WHERE meeting_tags.meetingId = meetings.id) AS tags
            FROM meetings
            LEFT JOIN project_paths AS projects
              ON projects.id = meetings.projectId
             AND projects.workspace_id = meetings.workspace_id
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
        do {
            let result = try cachedMeeting(id: id)
            touchText(entity: .summary, meetingId: id)
            return result
        } catch TextContentError.incomplete {
            guard let textResolver else { throw TextContentError.incomplete }
            return try JSONDecoder().decode(MeetingDetail.self, from: textResolver(workspaceID, .init(operation: .meeting, meetingId: id)))
        }
    }

    private func cachedMeeting(id: UUID) throws -> MeetingDetail {
        try database.read { db in
            let workspace = try fetchWorkspace(in: db)
            guard let row = try meetingRow(id: id, in: db) else {
                throw MeetingAccessError.meetingNotFound
            }
            let document = try TextContentAccess.summary(meetingId: id, in: db)?.document
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
            return try MeetingDetail(
                workspace: workspace,
                meeting: Self.metadata(from: row),
                summary: summary,
                summaryDocument: summaryDocument,
                summaryDocumentVersion: document.map(Self.summaryDocumentVersion),
                textContent: TextContentAccess.availability(entity: .summary, id: id, in: db)
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
        cursor: String? = nil,
        after: String? = nil,
        recordAccess: Bool = true
    ) throws -> TranscriptPage {
        do {
            let result = try cachedTranscript(
                meetingID: meetingID,
                fromElapsedSeconds: fromElapsedSeconds,
                toElapsedSeconds: toElapsedSeconds,
                limit: limit,
                cursor: cursor, after: after
            )
            if recordAccess { touchText(entity: .transcript, meetingId: meetingID) }
            return result
        } catch TextContentError.incomplete {
            guard let textResolver else { throw TextContentError.incomplete }
            _ = try JSONDecoder().decode(
                TranscriptPage.self,
                from: textResolver(
                    workspaceID,
                    .init(
                        operation: .transcript,
                        meetingId: meetingID,
                        cursor: cursor,
                        limit: limit,
                        fromElapsedSeconds: fromElapsedSeconds,
                        toElapsedSeconds: toElapsedSeconds
                    )
                )
            )
            return try cachedTranscript(
                meetingID: meetingID,
                fromElapsedSeconds: fromElapsedSeconds,
                toElapsedSeconds: toElapsedSeconds,
                limit: limit,
                cursor: cursor,
                after: after
            )
        }
    }

    private func touchText(entity: TextContentEntity, meetingId: UUID) {
        _ = try? textResolver?(workspaceID, .init(operation: .touch, meetingId: meetingId, entity: entity))
    }

    private func cachedTranscript(
        meetingID: UUID, fromElapsedSeconds: Double?, toElapsedSeconds: Double?, limit: Int, cursor: String?, after: String?
    ) throws -> TranscriptPage {
        guard after == nil || cursor == nil else { throw TranscriptAfterError.invalid }
        guard (1 ... 500).contains(limit) else {
            throw MeetingAccessError.invalidLimit(maximum: 500)
        }
        try validateTimeRange(from: fromElapsedSeconds, to: toElapsedSeconds)
        let decodedCursor = try cursor.map {
            try TranscriptCursor.decode(
                $0,
                workspaceID: workspaceID,
                meetingID: meetingID,
                fromElapsedSeconds: fromElapsedSeconds,
                toElapsedSeconds: toElapsedSeconds
            )
        }

        return try database.read { db in
            let workspace = try fetchWorkspace(in: db)
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM meetings WHERE id = ? AND workspace_id = ?)",
                arguments: [meetingID, workspaceID]
            ) == true else {
                throw MeetingAccessError.meetingNotFound
            }
            let resident = try TextContentAccess.availability(entity: .transcript, id: meetingID, in: db).revision
            if let expected = decodedCursor?.contentRevision, expected != resident { throw TextContentError.changed }
            let rows = try TextContentAccess.transcriptRows(
                meetingId: meetingID, order: fromElapsedSeconds == nil && toElapsedSeconds == nil ? .chronological : .elapsed,
                fromElapsedSeconds: fromElapsedSeconds, toElapsedSeconds: toElapsedSeconds,
                confirmedOnly: true, limit: nil, in: db
            )
            let entries = rows.map(Self.transcriptEntry(from:))
            let transcriptJSON = try String.fetchOne(db, sql: "SELECT infoJSON FROM transcripts WHERE meetingId = ?", arguments: [meetingID])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var transcript = try transcriptJSON.map { try decoder.decode(TranscriptInfo.self, from: Data($0.utf8)) }
            let generation = transcript?.id.uuidString ?? "none"
            let start: Int
            if let decodedCursor {
                guard let index = entries.firstIndex(where: { $0.id == decodedCursor.segmentID }) else { throw TextContentError.changed }
                start = index + 1
            } else { start = 0 }
            let page = try TranscriptAfter.page(
                workspaceID: workspaceID,
                meetingID: meetingID,
                from: fromElapsedSeconds,
                to: toElapsedSeconds,
                generation: generation,
                segments: entries,
                after: after,
                start: start,
                limit: limit
            )
            let segments = page.segments
            let hasMore = segments.last.map { $0.id != entries.last?.id } ?? false
            let nextCursor = hasMore ? segments.last.map {
                TranscriptCursor(
                    workspaceID: workspaceID,
                    meetingID: meetingID,
                    startedAt: $0.startedAt,
                    elapsedSeconds: $0.elapsedSeconds,
                    segmentID: $0.id,
                    fromElapsedSeconds: fromElapsedSeconds,
                    toElapsedSeconds: toElapsedSeconds,
                    contentRevision: resident
                ).encoded()
            } : nil
            transcript?.latestSegmentCreatedAt = try Date.fetchOne(
                db,
                sql: "SELECT MAX(createdAt) FROM transcript_segments WHERE meetingId = ?",
                arguments: [meetingID]
            )
            return try TranscriptPage(
                transcript: transcript,
                workspace: workspace,
                meetingID: meetingID,
                segments: segments,
                nextCursor: nextCursor,
                nextAfter: page.next,
                textContent: TextContentAccess.availability(entity: .transcript, id: meetingID, in: db)
            )
        }
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
    let icalUID: String?
    let attendee: String?
    let createdFrom: Date?
    let createdBefore: Date?
}

extension MeetingAccessStore {
    /// IDs may belong to different meetings of this workspace. An ID that fails is reported in `errors` without
    /// failing the others; nil marks an ID the caller sent in an invalid form. Without `includeImages`, image bytes
    /// are not read and a missing original only omits its file path.
    public func screenshots(
        ids screenshotIDs: [UUID?],
        includeImages: Bool = true
    ) throws -> (list: ScreenshotList, images: [MeetingScreenshotImage]) {
        let requested = Array(Set(screenshotIDs.compactMap(\.self)))
        let (workspace, rows) = try database.read { db in
            let workspace = try fetchWorkspace(in: db)
            return try (workspace, requested.isEmpty ? [] : screenshotImageRows(screenshotIDs: requested, includeImageData: includeImages, in: db))
        }
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as UUID, $0) })
        var referencedIDsByMeeting: [UUID: Set<UUID>] = [:]
        for meetingID in Set(rows.map { $0["meetingId"] as UUID }) {
            referencedIDsByMeeting[meetingID] = try? referencedScreenshotIDs(meetingID: meetingID)
        }
        var screenshots: [MeetingScreenshotMetadata] = []
        var images: [MeetingScreenshotImage] = []
        var errors: [ScreenshotIDError] = []
        for (index, id) in screenshotIDs.enumerated() {
            guard let id else {
                errors.append(ScreenshotIDError(index: index, screenshotID: nil, error: .invalidID))
                continue
            }
            guard let row = rowsByID[id] else {
                errors.append(ScreenshotIDError(index: index, screenshotID: id, error: .notFound))
                continue
            }
            let meetingID: UUID = row["meetingId"]
            guard let referencedIDs = referencedIDsByMeeting[meetingID] else {
                errors.append(ScreenshotIDError(index: index, screenshotID: id, error: .unavailable))
                continue
            }
            let metadata = screenshotMetadata(from: row, referencedIDs: referencedIDs)
            guard includeImages else {
                screenshots.append(metadata)
                continue
            }
            let payload = ScreenshotPayload(
                fileId: row["fileId"], metadata: metadata, imageData: row["imageData"], remoteReference: row["remoteReference"]
            )
            do {
                let image = try encodedScreenshot(payload)
                screenshots.append(image.metadata)
                images.append(image)
            } catch let error as MeetingAccessError where error == .screenshotUnavailable || error == .screenshotEncodingFailed {
                errors.append(ScreenshotIDError(
                    index: index, screenshotID: id, error: error == .screenshotUnavailable ? .unavailable : .unreadable
                ))
            }
        }
        return (ScreenshotList(workspace: workspace, screenshots: screenshots, errors: errors), images)
    }

    private func encodedScreenshot(_ payload: ScreenshotPayload) throws -> MeetingScreenshotImage {
        let meetingID = payload.metadata.meetingID
        var imageData = payload.imageData
        if imageData == nil, let json = payload.remoteReference,
           let source = try? JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(json.utf8)),
           source.fileId == payload.fileId {
            _ = try? textResolver?(workspaceID, .init(touchingFile: payload.fileId, meetingId: meetingID))
            imageData = try? screenshotCache?.read(source, variant: .original)?.data
        }
        if imageData == nil {
            imageData = try imageResolver(workspaceID, meetingID, payload.metadata.id)
        }
        guard let imageData else { throw MeetingAccessError.screenshotUnavailable }
        guard let mimeType = ImageEncoder.mimeType(for: imageData) else {
            throw MeetingAccessError.screenshotEncodingFailed
        }
        let metadata = MeetingScreenshotMetadata(
            id: payload.metadata.id,
            meetingID: meetingID,
            capturedAt: payload.metadata.capturedAt,
            elapsedSeconds: payload.metadata.elapsedSeconds,
            timestamp: payload.metadata.timestamp,
            mimeType: mimeType,
            isReferencedInSummary: payload.metadata.isReferencedInSummary,
            detectedText: payload.metadata.detectedText,
            caption: payload.metadata.caption,
            // The app may have migrated a legacy image into the file store while resolving it.
            filePath: payload.metadata.filePath ?? originalFilePath(reference: payload.remoteReference, fileId: payload.fileId)
        )
        return MeetingScreenshotImage(metadata: metadata, imageData: imageData, mimeType: mimeType)
    }

    func meetingExists(id: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM meetings WHERE id = ? AND workspace_id = ?)",
            arguments: [id, workspaceID]
        ) == true
    }

    private func screenshotImageRows(screenshotIDs: [UUID], includeImageData: Bool, in db: Database) throws -> [Row] {
        let referenceSelection = try Self.screenshotReferenceSelection(in: db)
        let placeholders = Array(repeating: "?", count: screenshotIDs.count).joined(separator: ", ")
        var arguments: StatementArguments = [workspaceID]
        arguments += StatementArguments(screenshotIDs)
        return try Row.fetchAll(
            db,
            sql: """
            SELECT
                meeting_images.id,
                meeting_images.meetingId,
                meeting_images.capturedAt,
                meeting_images.mimeType,
                meeting_images.ocrText,
                meeting_images.caption,
                meeting_images.fileId,
                \(includeImageData ? "meeting_images.imageData" : "NULL AS imageData"),
                \(referenceSelection),
                \(Self.elapsedSecondsSQL(timestampColumn: "meeting_images.capturedAt")) AS elapsedSeconds
            FROM meeting_images
            JOIN meetings ON meetings.id = meeting_images.meetingId
            LEFT JOIN recording_sessions AS sessions
              ON sessions.id = meeting_images.sessionId
             AND sessions.meetingId = meeting_images.meetingId
            WHERE meetings.workspace_id = ? AND meeting_images.id IN (\(placeholders))
            """,
            arguments: arguments
        )
    }

    private static func screenshotReferenceSelection(in db: Database) throws -> String {
        let columns = try db.columns(in: "meeting_images").map(\.name)
        return columns.contains("localReference")
            ? "coalesce(meeting_images.localReference, meeting_images.remoteReference) AS remoteReference"
            : columns.contains("remoteReference") ? "meeting_images.remoteReference" : "NULL AS remoteReference"
    }

    private func originalFilePath(reference: String?, fileId: UUID?) -> String? {
        guard let reference,
              let source = try? JSONDecoder().decode(ScreenshotRemoteReference.self, from: Data(reference.utf8)),
              source.fileId == fileId else { return nil }
        if let screenshotCache { return screenshotCache.existingOriginalFileURL(for: source)?.path }
        // The helper can start before the first capture creates the file index.
        guard database.path != ":memory:" else { return nil }
        let directory = URL(filePath: database.path).deletingLastPathComponent().appending(path: "FileStore")
        let url = directory.appending(path: source.cacheKey(variant: .original))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.path
    }

    private func screenshotMetadata(from row: Row, referencedIDs: Set<UUID>) -> MeetingScreenshotMetadata {
        let elapsed: Double = row["elapsedSeconds"]
        let id: UUID = row["id"]
        return MeetingScreenshotMetadata(
            id: id,
            meetingID: row["meetingId"],
            capturedAt: row["capturedAt"],
            elapsedSeconds: elapsed,
            timestamp: Self.timestamp(elapsedSeconds: elapsed),
            mimeType: row["mimeType"],
            isReferencedInSummary: referencedIDs.contains(id),
            detectedText: row["ocrText"],
            caption: row["caption"],
            filePath: originalFilePath(reference: row["remoteReference"], fileId: row["fileId"])
        )
    }

    private func referencedScreenshotIDs(meetingID: UUID) throws -> Set<UUID> {
        let data: Data?
        do {
            data = try database.read { db in
                _ = try fetchWorkspace(in: db)
                guard try meetingExists(id: meetingID, in: db) else { throw MeetingAccessError.meetingNotFound }
                return try TextContentAccess.summary(meetingId: meetingID, in: db)?.document.data(using: .utf8)
            }
        } catch TextContentError.incomplete {
            // Reuse the existing meeting broker operation outside SQLite; image reads also need exact summary references.
            data = try meeting(id: meetingID).summaryDocument.map { try JSONEncoder().encode($0) }
        }
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
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

    func validateSchema(in db: Database) throws {
        let meetingColumns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('meetings')")
        let summaryColumns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('summaries')"))
        let searchColumns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('search_documents_fts')"))
        let projectColumns = try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('projects')"))
        let legacySummaryColumns: Set = ["summary", "googleFileId", "workspaceRelativePath"]
        guard meetingColumns.contains("description"),
              try db.tableExists("summary_bodies"),
              try db.tableExists("transcript_segment_bodies"),
              try db.tableExists("file_text_bodies"),
              !summaryColumns.contains("document"),
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
    }

    func fetchWorkspace(in db: Database) throws -> ScopedWorkspace {
        try validateSchema(in: db)
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT id, name, accountConnectionId FROM workspaces WHERE id = ?",
            arguments: [workspaceID]
        ) else {
            throw MeetingAccessError.workspaceNotFound
        }
        try accountScope?.validate(in: db)
        guard accountScope?.contains(row) != false else { throw MeetingAccessError.workspaceNotFound }
        return ScopedWorkspace(id: row["id"], name: row["name"])
    }

    private func meetingRow(id: UUID, in db: Database) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: """
            WITH RECURSIVE project_paths(id, workspace_id, name) AS (
                SELECT id, workspace_id, name
                FROM projects
                WHERE parentProjectId IS NULL AND workspace_id = ?
                UNION ALL
                SELECT child.id, child.workspace_id, project_paths.name || '/' || child.name
                FROM projects AS child
                JOIN project_paths ON project_paths.id = child.parentProjectId
                WHERE child.workspace_id = ?
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
                EXISTS(SELECT 1 FROM recording_sessions rs WHERE rs.meetingId = meetings.id AND rs.endedAt IS NULL) AS isRecording,
                meetings.duration,
                meetings.createdAt,
                summaries.meetingId IS NOT NULL AS hasSummary,
                \(transcriptCountSQL(in: db)) AS transcriptSegmentCount,
                (SELECT GROUP_CONCAT(tags.name, char(31))
                 FROM meeting_tags JOIN tags ON tags.id = meeting_tags.tagId
                 WHERE meeting_tags.meetingId = meetings.id) AS tags
            FROM meetings
            LEFT JOIN project_paths AS projects
              ON projects.id = meetings.projectId
             AND projects.workspace_id = meetings.workspace_id
            LEFT JOIN calendar_events
              ON calendar_events.ical_uid = meetings.calendar_event_ical_uid
             AND calendar_events.recurrence_id = meetings.calendar_event_recurrence_id
            LEFT JOIN summaries ON summaries.meetingId = meetings.id
            WHERE meetings.id = ? AND meetings.workspace_id = ?
            """,
            arguments: [workspaceID, workspaceID, id, workspaceID]
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
            isRecording: row["isRecording"] ?? false,
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
              AND search_documents.workspace_id = meetings.workspace_id
              AND search_documents_fts MATCH ?
        )
        """)
        arguments += ["{title description summary calendar tags} : (\(query))"]
    }
}

private struct MeetingCursor: Codable {
    let workspaceID: UUID
    let scope: String
    let indexRevision: Int?
    let createdAt: Date
    let meetingID: UUID

    func encoded() -> String {
        AccessCursorCodec.encode(self)
    }

    static func decode(_ value: String, workspaceID: UUID, scope: String, indexRevision: Int?) throws -> Self {
        try AccessCursorCodec.decode(Self.self, from: value) { cursor in
            cursor.workspaceID == workspaceID && cursor.scope == scope && cursor.indexRevision == indexRevision
        }
    }
}

private final class SearchDeadline {
    private let deadline = ContinuousClock.now + .seconds(30)
    var hasExpired: Bool { ContinuousClock.now >= deadline }
}

private struct TranscriptCursor: Codable {
    let workspaceID: UUID
    let meetingID: UUID
    let startedAt: Date
    let elapsedSeconds: Double
    let segmentID: UUID
    let fromElapsedSeconds: Double?
    let toElapsedSeconds: Double?
    var contentRevision: Int?

    func encoded() -> String {
        AccessCursorCodec.encode(self)
    }

    static func decode(
        _ value: String,
        workspaceID: UUID,
        meetingID: UUID,
        fromElapsedSeconds: Double?,
        toElapsedSeconds: Double?
    ) throws -> Self {
        try AccessCursorCodec.decode(Self.self, from: value) { cursor in
            cursor.workspaceID == workspaceID
                && cursor.meetingID == meetingID
                && cursor.fromElapsedSeconds == fromElapsedSeconds
                && cursor.toElapsedSeconds == toElapsedSeconds
        }
    }
}

private struct ScreenshotTextCursor: Codable {
    let workspaceID: UUID
    let revision: Int
    let scope: String
    let offset: Int
    let capturedAt: Date?
    let elapsedSeconds: Double?
    let screenshotID: UUID?

    func encoded() -> String { AccessCursorCodec.encode(self) }

    static func decode(_ value: String, workspaceID: UUID, revision: Int, scope: String) throws -> Self {
        try AccessCursorCodec.decode(Self.self, from: value) {
            $0.workspaceID == workspaceID && $0.revision == revision && $0.scope == scope && $0.offset >= 0
        }
    }
}

private struct ScreenshotTextCursorFilterScope: Codable {
    let query: String?
    let projectID: UUID?
    let meetingID: UUID?
    let fromElapsedSeconds: Double?
    let toElapsedSeconds: Double?
    let createdFrom: Date?
    let createdBefore: Date?
}

private struct ServerSearchCursor: Codable { let scope: String
    let position: String
}
