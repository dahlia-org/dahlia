import Foundation
import GRDB

/// アプリ全体で単一の SQLite データベースを管理する。
/// `~/Library/Application Support/Dahlia/dahlia.sqlite` に配置する。
final class AppDatabaseManager: Sendable {
    let dbQueue: DatabaseQueue

    /// アプリケーションサポートディレクトリに DB を作成・オープンする。
    convenience init() throws {
        try self.init(path: Self.databaseURL.path)
    }

    init(path: String) throws {
        if path != ":memory:" {
            let dbURL = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: dbURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    /// DB ファイルの URL。
    nonisolated static var databaseURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Dahlia")
            .appendingPathComponent("dahlia.sqlite")
    }

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()

        // リリース後は既存ユーザーデータを保持する。破壊的な自動再作成は行わない。
        migrator.eraseDatabaseOnSchemaChange = false

        migrator.registerMigration("v3_googleDriveFolderSchema") { db in
            try createSchema(in: db)
        }

        migrator.registerMigration("v4_instructionsSchema") { db in
            try createInstructionsTableIfNeeded(in: db)
        }

        migrator.registerMigration("v5_summaryGoogleFileId") { db in
            try addSummaryGoogleFileIdColumnIfNeeded(in: db)
        }

        migrator.registerMigration("v6_transcriptSegmentTranslation") { db in
            try addTranscriptSegmentTranslatedTextColumnIfNeeded(in: db)
        }

        migrator.registerMigration("v7_normalizeLegacyMeetingStatus") { db in
            try normalizeLegacyMeetingStatus(in: db)
        }

        migrator.registerMigration("v8_recordingSessions") { db in
            try addRecordingSessionSchemaIfNeeded(in: db)
        }

        migrator.registerMigration("v9_summaryDocument") { db in
            try addSummaryDocumentColumnIfNeeded(in: db)
        }

        return migrator
    }()

    private static func createSchema(in db: Database) throws {
        try createVaultsTable(in: db)
        try createProjectsTable(in: db)
        try createMeetingsTable(in: db)
        try createTranscriptSegmentsTable(in: db)
        try createTagsTable(in: db)
        try createMeetingTagsTable(in: db)
        try createNotesTable(in: db)
        try createScreenshotsTable(in: db)
        try createSummariesTable(in: db)
        // Legacy table kept in the v3 migration for existing database compatibility.
        // The app no longer reads or writes action item rows.
        try createActionItemsTable(in: db)
        try createCalendarEventsTable(in: db)
        try createInstructionsTable(in: db)
    }

    private static func createVaultsTable(in db: Database) throws {
        try db.create(table: "vaults") { t in
            t.primaryKey("id", .blob)
            t.column("path", .text).notNull().unique()
            t.column("name", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("lastOpenedAt", .datetime).notNull()
        }
    }

    private static func createProjectsTable(in db: Database) throws {
        try db.create(table: "projects") { t in
            t.primaryKey("id", .blob)
            t.column("vaultId", .blob).notNull()
                .references("vaults", onDelete: .cascade)
            t.column("name", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("googleDriveFolderId", .text)
            t.column("missingOnDisk", .boolean).notNull().defaults(to: false)
            t.uniqueKey(["vaultId", "name"])
        }
        try db.create(
            index: "projects_on_vaultId",
            on: "projects",
            columns: ["vaultId"]
        )
    }

    private static func createMeetingsTable(in db: Database) throws {
        try db.create(table: "meetings") { t in
            t.primaryKey("id", .blob)
            t.column("vaultId", .blob).notNull()
                .references("vaults", onDelete: .cascade)
            t.column("projectId", .blob)
                .references("projects", onDelete: .setNull)
            t.column("name", .text).notNull().defaults(to: "")
            t.column("status", .text).notNull().defaults(to: MeetingStatus.transcriptNotFound.rawValue)
            t.column("duration", .double)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try db.create(
            index: "meetings_on_projectId",
            on: "meetings",
            columns: ["projectId"]
        )
        try db.create(
            index: "meetings_on_projectId_createdAt",
            on: "meetings",
            columns: ["projectId", "createdAt"]
        )
        try db.create(
            index: "meetings_on_vaultId_createdAt",
            on: "meetings",
            columns: ["vaultId", "createdAt"]
        )
    }

    private static func normalizeLegacyMeetingStatus(in db: Database) throws {
        guard try db.tableExists("meetings") else { return }
        try db.execute(
            sql: "UPDATE meetings SET status = ? WHERE status = ?",
            arguments: [MeetingStatus.ready.rawValue, "RECORDING"]
        )
    }

    private static func createTranscriptSegmentsTable(in db: Database) throws {
        try db.create(table: "transcript_segments") { t in
            t.primaryKey("id", .blob)
            t.column("meetingId", .blob).notNull()
                .references("meetings", onDelete: .cascade)
            t.column("startTime", .datetime).notNull()
            t.column("endTime", .datetime)
            t.column("text", .text).notNull()
            t.column("translatedText", .text)
            t.column("isConfirmed", .boolean).notNull().defaults(to: false)
            t.column("speakerLabel", .text)
        }
        try db.create(
            index: "transcript_segments_on_meetingId",
            on: "transcript_segments",
            columns: ["meetingId"]
        )
        try db.create(
            index: "transcript_segments_on_meetingId_startTime",
            on: "transcript_segments",
            columns: ["meetingId", "startTime"]
        )
    }

    private static func createTagsTable(in db: Database) throws {
        try db.create(table: "tags") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique()
            t.column("colorHex", .text).notNull().defaults(to: "#808080")
            t.column("createdAt", .datetime).notNull()
        }
    }

    private static func createMeetingTagsTable(in db: Database) throws {
        try db.create(table: "meeting_tags") { t in
            t.column("meetingId", .blob).notNull()
                .references("meetings", onDelete: .cascade)
            t.column("tagId", .integer).notNull()
                .references("tags", onDelete: .cascade)
            t.primaryKey(["meetingId", "tagId"])
        }
        try db.create(
            index: "meeting_tags_on_tagId",
            on: "meeting_tags",
            columns: ["tagId"]
        )
    }

    private static func createNotesTable(in db: Database) throws {
        try db.create(table: "notes") { t in
            t.primaryKey("meetingId", .blob)
                .references("meetings", onDelete: .cascade)
            t.column("text", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
    }

    private static func createScreenshotsTable(in db: Database) throws {
        try db.create(table: "screenshots") { t in
            t.primaryKey("id", .blob)
            t.column("meetingId", .blob).notNull()
                .references("meetings", onDelete: .cascade)
            t.column("capturedAt", .datetime).notNull()
            t.column("imageData", .blob).notNull()
            t.column("mimeType", .text).notNull()
        }
        try db.create(
            index: "screenshots_on_meetingId",
            on: "screenshots",
            columns: ["meetingId"]
        )
    }

    private static func createSummariesTable(in db: Database) throws {
        try db.create(table: "summaries") { t in
            t.primaryKey("meetingId", .blob)
                .references("meetings", onDelete: .cascade)
            t.column("title", .text).notNull().defaults(to: "")
            t.column("summary", .text).notNull()
            t.column("googleFileId", .text)
            t.column("createdAt", .datetime).notNull()
        }
    }

    private static func createActionItemsTable(in db: Database) throws {
        try db.create(table: "action_items") { t in
            t.primaryKey("id", .blob)
            t.column("meetingId", .blob).notNull()
                .references("meetings", onDelete: .cascade)
            t.column("title", .text).notNull()
            t.column("assignee", .text).notNull().defaults(to: "")
            t.column("isCompleted", .boolean).notNull().defaults(to: false)
        }
        try db.create(
            index: "action_items_on_meetingId",
            on: "action_items",
            columns: ["meetingId"]
        )
    }

    private static func createCalendarEventsTable(in db: Database) throws {
        try db.create(table: "calendar_events") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("meetingId", .blob).notNull()
                .references("meetings", onDelete: .cascade)
                .unique()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.column("platform", .text).notNull()
            t.column("platformId", .text).notNull()
            t.column("description", .text).notNull().defaults(to: "")
            t.column("icalUid", .text)
            t.column("start", .datetime).notNull()
            t.column("end", .datetime).notNull()
            t.column("meetingUrl", .text)
            t.uniqueKey(["platform", "platformId"])
        }
    }

    private static func createInstructionsTable(in db: Database) throws {
        try db.create(table: "instructions") { t in
            t.primaryKey("id", .blob)
            t.column("vaultId", .blob).notNull()
                .references("vaults", onDelete: .cascade)
            t.column("name", .text).notNull()
            t.column("content", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
            t.uniqueKey(["vaultId", "name"])
        }
        try db.create(
            index: "instructions_on_vaultId_name",
            on: "instructions",
            columns: ["vaultId", "name"]
        )
    }

    private static func createInstructionsTableIfNeeded(in db: Database) throws {
        guard try !db.tableExists("instructions") else { return }
        try createInstructionsTable(in: db)
    }

    @discardableResult
    private static func addColumnIfNeeded(
        in db: Database,
        table tableName: String,
        column columnName: String,
        type columnType: Database.ColumnType
    ) throws -> Bool {
        guard try db.tableExists(tableName) else { return false }
        let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('\(tableName)')")
        guard !columns.contains(columnName) else { return false }
        try db.alter(table: tableName) { t in
            t.add(column: columnName, columnType)
        }
        return true
    }

    private static func addSummaryGoogleFileIdColumnIfNeeded(in db: Database) throws {
        guard try db.tableExists("summaries") else { return }

        let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('summaries')")

        if !columns.contains("googleFileId") {
            try db.alter(table: "summaries") { t in
                t.add(column: "googleFileId", .text)
            }
        }

        if columns.contains("googleDocumentId") {
            try db.execute(
                sql: """
                UPDATE summaries
                SET googleFileId = COALESCE(googleFileId, googleDocumentId)
                WHERE googleDocumentId IS NOT NULL
                """
            )
        }
    }

    private static func addTranscriptSegmentTranslatedTextColumnIfNeeded(in db: Database) throws {
        try addColumnIfNeeded(in: db, table: "transcript_segments", column: "translatedText", type: .text)
    }

    private static func addRecordingSessionSchemaIfNeeded(in db: Database) throws {
        if try db.tableExists("meetings") {
            try createRecordingSessionsTableIfNeeded(in: db)
        }

        try addColumnIfNeeded(in: db, table: "transcript_segments", column: "sessionId", type: .blob)
        try addColumnIfNeeded(in: db, table: "screenshots", column: "sessionId", type: .blob)

        if try db.tableExists("meetings"),
           try db.tableExists("recording_sessions") {
            try backfillRecordingSessions(in: db)
        }
    }

    private static func addSummaryDocumentColumnIfNeeded(in db: Database) throws {
        try addColumnIfNeeded(in: db, table: "summaries", column: "document", type: .text)
        try backfillSummaryDocuments(in: db)
    }

    private static func backfillSummaryDocuments(in db: Database) throws {
        guard try db.tableExists("summaries") else { return }
        let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('summaries')")
        guard columns.contains("document") else { return }

        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT meetingId, title, summary, createdAt
            FROM summaries
            WHERE document IS NULL OR TRIM(document) = ''
            """
        )
        guard !rows.isEmpty else { return }

        for row in rows {
            let meetingId: UUID = row["meetingId"]
            let title: String = row["title"]
            let summary: String = row["summary"]
            let createdAt: Date = row["createdAt"]
            let context = try summaryBackfillContext(in: db, meetingId: meetingId, createdAt: createdAt)
            let document = LegacyMarkdownSummaryParser.parse(markdown: summary, title: title, context: context)
            try db.execute(
                sql: "UPDATE summaries SET document = ? WHERE meetingId = ?",
                arguments: [document.databaseJSONString(), meetingId]
            )
        }
    }

    private static func summaryBackfillContext(in db: Database, meetingId: UUID, createdAt: Date) throws -> SummaryRenderContext {
        let screenshots = if try db.tableExists("screenshots") {
            try MeetingScreenshotRecord
                .filter(Column("meetingId") == meetingId)
                .fetchAll(db)
        } else {
            [MeetingScreenshotRecord]()
        }

        return SummaryRenderContext(meetingId: meetingId, createdAt: createdAt, screenshots: screenshots)
    }

    private static func createRecordingSessionsTableIfNeeded(in db: Database) throws {
        guard try !db.tableExists("recording_sessions") else { return }
        try db.create(table: "recording_sessions") { t in
            t.primaryKey("id", .blob)
            t.column("meetingId", .blob).notNull()
                .references("meetings", onDelete: .cascade)
            t.column("startedAt", .datetime).notNull()
            t.column("endedAt", .datetime)
            t.column("duration", .double)
            t.column("offsetSeconds", .double).notNull().defaults(to: 0)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
        try db.create(
            index: "recording_sessions_on_meetingId",
            on: "recording_sessions",
            columns: ["meetingId"]
        )
        try db.create(
            index: "recording_sessions_on_meetingId_startedAt",
            on: "recording_sessions",
            columns: ["meetingId", "startedAt"]
        )
    }

    private static func backfillRecordingSessions(in db: Database) throws {
        let hasTranscriptSegments = try db.tableExists("transcript_segments")
        let hasScreenshots = try db.tableExists("screenshots")

        let rows: [Row] = if hasTranscriptSegments {
            try Row.fetchAll(
                db,
                sql: """
                SELECT
                    meetings.id AS meetingId,
                    meetings.createdAt AS meetingCreatedAt,
                    meetings.duration AS meetingDuration,
                    MIN(transcript_segments.startTime) AS firstSegmentStartTime,
                    MAX(COALESCE(transcript_segments.endTime, transcript_segments.startTime)) AS lastSegmentEndTime
                FROM meetings
                LEFT JOIN transcript_segments ON transcript_segments.meetingId = meetings.id
                LEFT JOIN recording_sessions ON recording_sessions.meetingId = meetings.id
                WHERE recording_sessions.id IS NULL
                GROUP BY meetings.id
                """
            )
        } else {
            try Row.fetchAll(
                db,
                sql: """
                SELECT
                    meetings.id AS meetingId,
                    meetings.createdAt AS meetingCreatedAt,
                    meetings.duration AS meetingDuration,
                    NULL AS firstSegmentStartTime,
                    NULL AS lastSegmentEndTime
                FROM meetings
                LEFT JOIN recording_sessions ON recording_sessions.meetingId = meetings.id
                WHERE recording_sessions.id IS NULL
                GROUP BY meetings.id
                """
            )
        }

        for row in rows {
            let meetingId: UUID = row["meetingId"]
            let meetingCreatedAt: Date = row["meetingCreatedAt"]
            let meetingDuration: TimeInterval? = row["meetingDuration"]
            let firstSegmentStartTime: Date? = row["firstSegmentStartTime"]
            let lastSegmentEndTime: Date? = row["lastSegmentEndTime"]
            let startedAt = firstSegmentStartTime ?? meetingCreatedAt
            let transcriptDuration = lastSegmentEndTime.map { max(0, $0.timeIntervalSince(startedAt)) }
            let duration = transcriptDuration ?? meetingDuration
            let endedAt = lastSegmentEndTime
                ?? duration.map { startedAt.addingTimeInterval($0) }
            let sessionId = UUID.v7()

            try db.execute(
                sql: """
                INSERT INTO recording_sessions (
                    id, meetingId, startedAt, endedAt, duration, offsetSeconds, createdAt, updatedAt
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    sessionId,
                    meetingId,
                    startedAt,
                    endedAt,
                    duration,
                    0,
                    startedAt,
                    endedAt ?? startedAt,
                ]
            )

            if hasTranscriptSegments {
                try db.execute(
                    sql: """
                    UPDATE transcript_segments
                    SET sessionId = ?
                    WHERE meetingId = ? AND sessionId IS NULL
                    """,
                    arguments: [sessionId, meetingId]
                )
            }

            if hasScreenshots {
                try db.execute(
                    sql: """
                    UPDATE screenshots
                    SET sessionId = ?
                    WHERE meetingId = ? AND sessionId IS NULL
                    """,
                    arguments: [sessionId, meetingId]
                )
            }
        }
    }
}
