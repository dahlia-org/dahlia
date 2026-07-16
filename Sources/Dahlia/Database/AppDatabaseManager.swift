// Migration order and helpers remain colocated so the complete schema history can be audited sequentially.
// swiftlint:disable file_length

import Foundation
import GRDB

/// アプリ全体で単一の SQLite データベースを管理する。
/// `~/Library/Application Support/Dahlia/dahlia.sqlite` に配置する。
// swiftlint:disable:next type_body_length
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
        if path != ":memory:" {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        }
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

        migrator.registerMigration("v10_batchTranscription") { db in
            try addBatchTranscriptionSchemaIfNeeded(in: db)
        }

        migrator.registerMigration("v11_batchAudioStorageLocation") { db in
            try addBatchAudioStorageLocationIfNeeded(in: db)
        }

        migrator.registerMigration("v12_batchTranscriptionDiscard") { db in
            try addBatchDiscardedAtColumnIfNeeded(in: db)
        }

        migrator.registerMigration("v13_summaryVaultRelativePath") { db in
            try addSummaryVaultRelativePathColumnIfNeeded(in: db)
        }

        migrator.registerMigration("v14_projectDescription") { db in
            try addProjectDescriptionColumnIfNeeded(in: db)
        }

        migrator.registerMigration("v15_calendarEventIdentity") { db in
            try replaceCalendarEventSchema(in: db)
        }

        migrator.registerMigration("v16_calendarEventURL") { db in
            try moveCalendarEventURLToCanonicalTable(in: db)
        }

        migrator.registerMigration("v17_calendarEventIntegrity") { db in
            try strengthenCalendarEventIntegrity(in: db)
        }

        migrator.registerMigration("v18_segmentedRecordingAudio") { db in
            try addSegmentedRecordingAudioSchema(in: db)
        }

        migrator.registerMigration("v19_summaryExports") { db in
            try SummaryExportsMigration.migrate(in: db)
        }

        migrator.registerMigration("v20_meetingDescription") { db in
            try addMeetingDescriptionColumnIfNeeded(in: db)
        }

        migrator.registerMigration("v21_removeLegacySummaryColumns") { db in
            try LegacySummaryColumnsMigration.migrate(in: db)
        }

        return migrator
    }()

    private static func addMeetingDescriptionColumnIfNeeded(in db: Database) throws {
        guard try db.tableExists("meetings") else { return }
        let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('meetings')")
        guard !columns.contains("description") else { return }
        try db.alter(table: "meetings") { table in
            table.add(column: "description", .text)
                .notNull()
                .defaults(to: "")
        }
    }

    // The segmented recording tables form one atomic schema migration.
    // swiftlint:disable:next function_body_length
    private static func addSegmentedRecordingAudioSchema(in db: Database) throws {
        // Some early development databases can legitimately contain only a subset of
        // the v3 schema. Keep those databases migratable without manufacturing parent
        // rows or weakening the foreign-key relationships of the segmented store.
        guard try db.tableExists("recording_sessions") else { return }

        try addColumnIfNeeded(
            in: db,
            table: "recording_sessions",
            column: "audioRetentionPolicy",
            type: .text
        )
        try addColumnIfNeeded(
            in: db,
            table: "recording_sessions",
            column: "retentionExpiresAt",
            type: .datetime
        )
        try addColumnIfNeeded(
            in: db,
            table: "recording_sessions",
            column: "batchFailureKind",
            type: .text
        )
        if try !db.tableExists("recording_audio_segments") {
            try db.create(table: "recording_audio_segments") { table in
                table.primaryKey("id", .blob)
                table.column("recordingSessionId", .blob).notNull()
                    .references("recording_sessions", onDelete: .cascade)
                table.column("source", .text).notNull()
                table.column("segmentIndex", .integer).notNull()
                table.column("generationId", .blob).notNull().unique()
                table.column("state", .text).notNull()
                table.column("partialRelativePath", .text).notNull().unique()
                table.column("finalRelativePath", .text).notNull().unique()
                table.column("sampleRate", .double).notNull()
                table.column("channelCount", .integer).notNull()
                table.column("sealedFrameCount", .integer)
                table.column("sessionStartOffsetSeconds", .double).notNull()
                table.column("sessionEndOffsetSeconds", .double)
                table.column("byteCount", .integer)
                table.column("sha256", .blob)
                table.column("finalizationStartedAt", .datetime)
                table.column("integrityVerifiedAt", .datetime)
                table.column("finalizedAt", .datetime)
                table.column("purgeRequestedAt", .datetime)
                table.column("purgedAt", .datetime)
                table.column("failureStage", .text)
                table.column("failureCode", .text)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.uniqueKey(["recordingSessionId", "source", "segmentIndex"])
            }
            try db.create(
                index: "recording_audio_segments_on_session_state",
                on: "recording_audio_segments",
                columns: ["recordingSessionId", "state"]
            )
            try db.create(
                index: "recording_audio_segments_on_source_index",
                on: "recording_audio_segments",
                columns: ["recordingSessionId", "source", "segmentIndex"]
            )
        }

        if try !db.tableExists("recording_audio_segment_ranges") {
            try db.create(table: "recording_audio_segment_ranges") { table in
                table.primaryKey("id", .blob)
                table.column("audioSegmentId", .blob).notNull()
                    .references("recording_audio_segments", onDelete: .cascade)
                table.column("startFrame", .integer).notNull()
                table.column("frameCount", .integer)
                table.column("sessionOffsetSeconds", .double).notNull()
                table.column("localeIdentifier", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "recording_audio_segment_ranges_on_segment_frame",
                on: "recording_audio_segment_ranges",
                columns: ["audioSegmentId", "startFrame"]
            )
        }

        if try !db.tableExists("recording_audio_source_progress") {
            try db.create(table: "recording_audio_source_progress") { table in
                table.column("recordingSessionId", .blob).notNull()
                    .references("recording_sessions", onDelete: .cascade)
                table.column("source", .text).notNull()
                table.column("isRequired", .boolean).notNull().defaults(to: false)
                table.column("captureState", .text).notNull()
                table.column("durableThroughOffsetSeconds", .double).notNull().defaults(to: 0)
                table.column("lastContiguousReadySegmentIndex", .integer)
                table.column("failureCode", .text)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.primaryKey(["recordingSessionId", "source"])
            }
        }

        if try !db.tableExists("recording_audio_reconciliation_issues") {
            try db.create(table: "recording_audio_reconciliation_issues") { table in
                table.primaryKey("id", .blob)
                table.column("recordingSessionId", .blob)
                    .references("recording_sessions", onDelete: .cascade)
                table.column("audioSegmentId", .blob)
                    .references("recording_audio_segments", onDelete: .cascade)
                table.column("relativePath", .text)
                table.column("reason", .text).notNull()
                table.column("firstObservedAt", .datetime).notNull()
                table.column("lastObservedAt", .datetime).notNull()
                table.column("resolvedAt", .datetime)
            }
            try db.create(
                index: "recording_audio_reconciliation_issues_on_session",
                on: "recording_audio_reconciliation_issues",
                columns: ["recordingSessionId", "resolvedAt"]
            )
        }
    }

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
            // Kept for compatibility with databases migrated by v3. The app no longer reads or writes this value.
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
    }

    private static func addSummaryVaultRelativePathColumnIfNeeded(in db: Database) throws {
        try addColumnIfNeeded(in: db, table: "summaries", column: "vaultRelativePath", type: .text)
    }

    private static func addProjectDescriptionColumnIfNeeded(in db: Database) throws {
        guard try db.tableExists("projects") else { return }
        let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('projects')")
        guard !columns.contains("description") || !columns.contains("legacyContextMigrated") else { return }

        try db.alter(table: "projects") { table in
            if !columns.contains("description") {
                table.add(column: "description", .text)
                    .notNull()
                    .defaults(to: "")
            }
            if !columns.contains("legacyContextMigrated") {
                table.add(column: "legacyContextMigrated", .boolean)
                    .notNull()
                    .defaults(to: false)
            }
        }
    }

    private static func replaceCalendarEventSchema(in db: Database) throws {
        if try db.tableExists("calendar_event_sources") {
            try db.drop(table: "calendar_event_sources")
        }
        if try db.tableExists("calendar_events") {
            // Calendar event rows are a cache. Meetings and all other user-authored data are retained.
            try db.drop(table: "calendar_events")
        }

        try createCanonicalCalendarEventTables(in: db)
        try addCalendarEventReferenceColumns(in: db)
    }

    private static func moveCalendarEventURLToCanonicalTable(in db: Database) throws {
        guard try db.tableExists("calendar_events") else { return }
        try addColumnIfNeeded(in: db, table: "calendar_events", column: "url", type: .text)

        guard try db.tableExists("calendar_event_sources") else { return }
        let sourceColumns = try String.fetchAll(
            db,
            sql: "SELECT name FROM pragma_table_info('calendar_event_sources')"
        )
        guard sourceColumns.contains("source_event_url") else { return }

        try db.execute(
            sql: """
            UPDATE calendar_events
            SET url = (
                SELECT source_event_url
                FROM calendar_event_sources
                WHERE calendar_event_sources.ical_uid = calendar_events.ical_uid
                  AND calendar_event_sources.recurrence_id = calendar_events.recurrence_id
                  AND source_event_url IS NOT NULL
                  AND trim(source_event_url) <> ''
                ORDER BY
                    CASE WHEN platform = ? THEN 0 ELSE 1 END,
                    updated_at DESC,
                    calendar_id,
                    platform_id
                LIMIT 1
            )
            WHERE url IS NULL
            """,
            arguments: [CalendarEventPlatform.googleCalendar]
        )
        try db.execute(sql: "ALTER TABLE calendar_event_sources DROP COLUMN source_event_url")
    }

    private static func strengthenCalendarEventIntegrity(in db: Database) throws {
        guard try db.tableExists("calendar_events") else { return }
        try normalizeLegacyDateRecurrenceIDs(in: db)

        guard try db.tableExists("meetings") else { return }
        try replaceCalendarEventMeetingIndex(in: db)
        try deleteUnreferencedCalendarEvents(in: db)
        try createCalendarEventCleanupTriggers(in: db)
    }

    private static func normalizeLegacyDateRecurrenceIDs(in db: Database) throws {
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO calendar_events (
                ical_uid,
                recurrence_id,
                created_at,
                updated_at,
                title,
                description,
                start,
                "end",
                is_all_day,
                conference_uri,
                url
            )
            SELECT
                ical_uid,
                substr(recurrence_id, 12),
                created_at,
                updated_at,
                title,
                description,
                start,
                "end",
                is_all_day,
                conference_uri,
                url
            FROM calendar_events
            WHERE recurrence_id GLOB 'VALUE=DATE:[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
            """
        )
        if try db.tableExists("calendar_event_sources") {
            try db.execute(
                sql: """
                UPDATE calendar_event_sources
                SET recurrence_id = substr(recurrence_id, 12)
                WHERE recurrence_id GLOB 'VALUE=DATE:[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
                """
            )
        }
        if try db.tableExists("meetings") {
            try db.execute(
                sql: """
                UPDATE meetings
                SET calendar_event_recurrence_id = substr(calendar_event_recurrence_id, 12)
                WHERE calendar_event_recurrence_id
                    GLOB 'VALUE=DATE:[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
                """
            )
        }
        try db.execute(
            sql: """
            DELETE FROM calendar_events
            WHERE recurrence_id GLOB 'VALUE=DATE:[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
            """
        )
    }

    private static func replaceCalendarEventMeetingIndex(in db: Database) throws {
        try db.execute(sql: "DROP INDEX IF EXISTS meetings_on_calendar_event")
        try db.execute(
            sql: """
            CREATE INDEX meetings_on_calendar_event
            ON meetings (
                vaultId,
                calendar_event_ical_uid,
                calendar_event_recurrence_id,
                createdAt,
                id
            )
            """
        )
    }

    private static func deleteUnreferencedCalendarEvents(in db: Database) throws {
        try db.execute(
            sql: """
            DELETE FROM calendar_events
            WHERE NOT EXISTS (
                SELECT 1
                FROM meetings
                WHERE meetings.calendar_event_ical_uid = calendar_events.ical_uid
                  AND meetings.calendar_event_recurrence_id = calendar_events.recurrence_id
            )
            """
        )
    }

    private static func createCalendarEventCleanupTriggers(in db: Database) throws {
        try db.execute(
            sql: """
            CREATE TRIGGER meetings_calendar_event_cleanup_delete
            AFTER DELETE ON meetings
            WHEN OLD.calendar_event_ical_uid IS NOT NULL
            BEGIN
                DELETE FROM calendar_events
                WHERE ical_uid = OLD.calendar_event_ical_uid
                  AND recurrence_id = OLD.calendar_event_recurrence_id
                  AND NOT EXISTS (
                      SELECT 1
                      FROM meetings
                      WHERE calendar_event_ical_uid = OLD.calendar_event_ical_uid
                        AND calendar_event_recurrence_id = OLD.calendar_event_recurrence_id
                  );
            END
            """
        )
        try db.execute(
            sql: """
            CREATE TRIGGER meetings_calendar_event_cleanup_update
            AFTER UPDATE OF calendar_event_ical_uid, calendar_event_recurrence_id ON meetings
            WHEN OLD.calendar_event_ical_uid IS NOT NULL
              AND (
                  OLD.calendar_event_ical_uid IS NOT NEW.calendar_event_ical_uid
                  OR OLD.calendar_event_recurrence_id IS NOT NEW.calendar_event_recurrence_id
              )
            BEGIN
                DELETE FROM calendar_events
                WHERE ical_uid = OLD.calendar_event_ical_uid
                  AND recurrence_id = OLD.calendar_event_recurrence_id
                  AND NOT EXISTS (
                      SELECT 1
                      FROM meetings
                      WHERE calendar_event_ical_uid = OLD.calendar_event_ical_uid
                        AND calendar_event_recurrence_id = OLD.calendar_event_recurrence_id
                  );
            END
            """
        )
    }

    private static func createCanonicalCalendarEventTables(in db: Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE calendar_events (
                ical_uid TEXT NOT NULL,
                recurrence_id TEXT NOT NULL DEFAULT '',
                created_at DATETIME NOT NULL,
                updated_at DATETIME NOT NULL,
                title TEXT NOT NULL DEFAULT '',
                description TEXT NOT NULL DEFAULT '',
                start DATETIME NOT NULL,
                "end" DATETIME NOT NULL,
                is_all_day BOOLEAN NOT NULL DEFAULT 0,
                conference_uri TEXT CHECK (conference_uri IS NULL OR trim(conference_uri) <> ''),
                PRIMARY KEY (ical_uid, recurrence_id)
            ) WITHOUT ROWID
            """
        )
        try db.execute(
            sql: """
            CREATE TABLE calendar_event_sources (
                platform TEXT NOT NULL,
                calendar_id TEXT NOT NULL,
                platform_id TEXT NOT NULL,
                ical_uid TEXT NOT NULL,
                recurrence_id TEXT NOT NULL,
                source_event_url TEXT,
                created_at DATETIME NOT NULL,
                updated_at DATETIME NOT NULL,
                PRIMARY KEY (platform, calendar_id, platform_id),
                FOREIGN KEY (ical_uid, recurrence_id)
                    REFERENCES calendar_events (ical_uid, recurrence_id)
                    ON UPDATE CASCADE
                    ON DELETE CASCADE
            ) WITHOUT ROWID
            """
        )
        try db.execute(
            sql: """
            CREATE INDEX calendar_event_sources_on_event
            ON calendar_event_sources (ical_uid, recurrence_id)
            """
        )
    }

    private static func addCalendarEventReferenceColumns(in db: Database) throws {
        guard try db.tableExists("meetings") else { return }
        try addColumnIfNeeded(
            in: db,
            table: "meetings",
            column: "calendar_event_ical_uid",
            type: .text
        )
        try addColumnIfNeeded(
            in: db,
            table: "meetings",
            column: "calendar_event_recurrence_id",
            type: .text
        )
        try db.execute(
            sql: """
            CREATE INDEX meetings_on_calendar_event
            ON meetings (calendar_event_ical_uid, calendar_event_recurrence_id, createdAt)
            """
        )
        // SQLite は ALTER TABLE で複合外部キーを追加できない。meetings を再作成せず
        // ユーザーデータを保持するため、同等の参照制約をトリガーで適用する。
        try createCalendarEventReferenceTriggers(in: db)
    }

    private static func createCalendarEventReferenceTriggers(in db: Database) throws {
        try createMeetingCalendarEventReferenceTriggers(in: db)
        try createCalendarEventMutationTriggers(in: db)
    }

    private static func createMeetingCalendarEventReferenceTriggers(in db: Database) throws {
        try db.execute(
            sql: """
            CREATE TRIGGER meetings_calendar_event_reference_insert
            BEFORE INSERT ON meetings
            WHEN
                (NEW.calendar_event_ical_uid IS NULL) <> (NEW.calendar_event_recurrence_id IS NULL)
                OR (
                    NEW.calendar_event_ical_uid IS NOT NULL
                    AND NOT EXISTS (
                        SELECT 1
                        FROM calendar_events
                        WHERE ical_uid = NEW.calendar_event_ical_uid
                          AND recurrence_id = NEW.calendar_event_recurrence_id
                    )
                )
            BEGIN
                SELECT RAISE(ABORT, 'invalid calendar event reference');
            END
            """
        )
        try db.execute(
            sql: """
            CREATE TRIGGER meetings_calendar_event_reference_update
            BEFORE UPDATE OF calendar_event_ical_uid, calendar_event_recurrence_id ON meetings
            WHEN
                (NEW.calendar_event_ical_uid IS NULL) <> (NEW.calendar_event_recurrence_id IS NULL)
                OR (
                    NEW.calendar_event_ical_uid IS NOT NULL
                    AND NOT EXISTS (
                        SELECT 1
                        FROM calendar_events
                        WHERE ical_uid = NEW.calendar_event_ical_uid
                          AND recurrence_id = NEW.calendar_event_recurrence_id
                    )
                )
            BEGIN
                SELECT RAISE(ABORT, 'invalid calendar event reference');
            END
            """
        )
    }

    private static func createCalendarEventMutationTriggers(in db: Database) throws {
        try db.execute(
            sql: """
            CREATE TRIGGER calendar_events_reference_delete
            BEFORE DELETE ON calendar_events
            WHEN EXISTS (
                SELECT 1
                FROM meetings
                WHERE calendar_event_ical_uid = OLD.ical_uid
                  AND calendar_event_recurrence_id = OLD.recurrence_id
            )
            BEGIN
                SELECT RAISE(ABORT, 'calendar event is referenced by a meeting');
            END
            """
        )
        try db.execute(
            sql: """
            CREATE TRIGGER calendar_events_reference_update
            AFTER UPDATE OF ical_uid, recurrence_id ON calendar_events
            BEGIN
                UPDATE meetings
                SET calendar_event_ical_uid = NEW.ical_uid,
                    calendar_event_recurrence_id = NEW.recurrence_id
                WHERE calendar_event_ical_uid = OLD.ical_uid
                  AND calendar_event_recurrence_id = OLD.recurrence_id;
            END
            """
        )
    }

    private static func addBatchTranscriptionSchemaIfNeeded(in db: Database) throws {
        guard try db.tableExists("recording_sessions") else { return }

        let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('recording_sessions')")
        let requiredColumns = [
            "transcriptionMode",
            "retainAudioAfterBatch",
            "batchCompletedAt",
            "batchLastError",
            "batchLastAttemptAt",
            "batchAttemptCount",
        ]
        if requiredColumns.contains(where: { !columns.contains($0) }) {
            try db.alter(table: "recording_sessions") { table in
                if !columns.contains("transcriptionMode") {
                    table.add(column: "transcriptionMode", .text)
                        .notNull()
                        .defaults(to: TranscriptionMode.realtime.rawValue)
                }
                if !columns.contains("retainAudioAfterBatch") {
                    table.add(column: "retainAudioAfterBatch", .boolean)
                        .notNull()
                        .defaults(to: false)
                }
                if !columns.contains("batchCompletedAt") {
                    table.add(column: "batchCompletedAt", .datetime)
                }
                if !columns.contains("batchLastError") {
                    table.add(column: "batchLastError", .text)
                }
                if !columns.contains("batchLastAttemptAt") {
                    table.add(column: "batchLastAttemptAt", .datetime)
                }
                if !columns.contains("batchAttemptCount") {
                    table.add(column: "batchAttemptCount", .integer)
                        .notNull()
                        .defaults(to: 0)
                }
            }
        }

        if try !db.tableExists("recording_audio_files") {
            try db.create(table: "recording_audio_files") { table in
                table.primaryKey("id", .blob)
                table.column("recordingSessionId", .blob).notNull()
                    .references("recording_sessions", onDelete: .cascade)
                table.column("source", .text).notNull()
                table.column("relativePath", .text).notNull()
                table.column("sampleRate", .double).notNull()
                table.column("channelCount", .integer).notNull()
                table.column("finalizedAt", .datetime)
                table.column("totalFrameCount", .integer)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.uniqueKey(["recordingSessionId", "source"])
            }
            try db.create(
                index: "recording_audio_files_on_recordingSessionId",
                on: "recording_audio_files",
                columns: ["recordingSessionId"]
            )
        }

        if try !db.tableExists("recording_audio_ranges") {
            try db.create(table: "recording_audio_ranges") { table in
                table.primaryKey("id", .blob)
                table.column("audioFileId", .blob).notNull()
                    .references("recording_audio_files", onDelete: .cascade)
                table.column("startFrame", .integer).notNull()
                table.column("frameCount", .integer)
                table.column("sessionOffsetSeconds", .double).notNull()
                table.column("localeIdentifier", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "recording_audio_ranges_on_audioFileId_startFrame",
                on: "recording_audio_ranges",
                columns: ["audioFileId", "startFrame"]
            )
        }
    }

    private static func addBatchAudioStorageLocationIfNeeded(in db: Database) throws {
        guard try db.tableExists("recording_audio_files") else { return }
        let columns = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('recording_audio_files')")
        guard !columns.contains("storageLocation") else { return }

        // v10までのCAFはVaultへ直接保存していたため、既存行はvaultとして扱う。
        try db.alter(table: "recording_audio_files") { table in
            table.add(column: "storageLocation", .text)
                .notNull()
                .defaults(to: RecordingAudioStorageLocation.vault.rawValue)
        }
    }

    private static func addBatchDiscardedAtColumnIfNeeded(in db: Database) throws {
        try addColumnIfNeeded(
            in: db,
            table: "recording_sessions",
            column: "batchDiscardedAt",
            type: .datetime
        )
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
