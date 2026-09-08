import Foundation
import GRDB

/// Preserve speech timestamps; backfill historical generation times with the agreed meeting end proxy.
enum TranscriptActivityMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists("transcript_segments"), try db.tableExists("meetings") else { return }
        var columns = try Set(db.columns(in: "transcript_segments").map(\.name))
        if columns.contains("startTime") {
            try db.execute(sql: "ALTER TABLE transcript_segments RENAME COLUMN startTime TO startedAt")
        }
        if columns.contains("endTime") {
            try db.execute(sql: "ALTER TABLE transcript_segments RENAME COLUMN endTime TO endedAt")
        }
        if !columns.contains("createdAt") {
            try db.alter(table: "transcript_segments") { $0.add(column: "createdAt", .datetime) }
        }
        if columns.contains("isConfirmed") {
            try db.execute(sql: """
            DELETE FROM transcript_segments WHERE isConfirmed = 0;
            DROP INDEX IF EXISTS transcript_segments_on_meetingId_isConfirmed_startTime_id;
            ALTER TABLE transcript_segments DROP COLUMN isConfirmed;
            CREATE INDEX IF NOT EXISTS transcript_segments_on_meetingId_startedAt_id ON transcript_segments(meetingId, startedAt, id);
            """)
        }
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS transcript_segments_on_meetingId_createdAt ON transcript_segments(meetingId, createdAt)")
        if try db.tableExists("sync_transcript_patch_items") {
            columns = try Set(db.columns(in: "sync_transcript_patch_items").map(\.name))
            if !columns.contains("createdAt") {
                try db.alter(table: "sync_transcript_patch_items") { $0.add(column: "createdAt", .datetime) }
            }
        }
        guard try db.tableExists("meetings") else { return }
        for meeting in try MeetingRecord.fetchAll(db) {
            let sessions = try RecordingSessionRecord.filter(Column("meetingId") == meeting.id).fetchAll(db)
            let endedAt: Date? = if sessions.contains(where: { $0.endedAt == nil }) {
                nil
            } else if let end = sessions.compactMap(\.endedAt).max() {
                end
            } else {
                meeting.duration.map { meeting.effectiveRecordingStartedAt.addingTimeInterval($0) }
            }
            guard let endedAt else { continue }
            try db.execute(
                sql: "UPDATE transcript_segments SET createdAt = ? WHERE meetingId = ? AND createdAt IS NULL",
                arguments: [endedAt, meeting.id]
            )
            if try db.tableExists("sync_transcript_patch_items") {
                try db.execute(sql: """
                UPDATE sync_transcript_patch_items SET createdAt = ?
                WHERE createdAt IS NULL AND action = 'upsert' AND operationId IN
                    (SELECT id FROM sync_operations WHERE entity = 'transcript' AND entityId = ?)
                """, arguments: [endedAt, meeting.id])
            }
        }
        if try db.tableExists("transcripts") {
            try db.execute(sql: """
            UPDATE transcripts SET infoJSON = json_remove(json_set(infoJSON,
                '$.endedAt', COALESCE(json_extract(infoJSON, '$.endedAt'), json_extract(infoJSON, '$.completedAt')),
                '$.createdAt', COALESCE(json_extract(infoJSON, '$.createdAt'), json_extract(infoJSON, '$.savedAt'))),
                '$.status', '$.completedAt', '$.savedAt');
            """)
        }
        if try db.tableExists("sync_operations") {
            try db.execute(sql: """
            UPDATE sync_operations SET payloadJSON = json_remove(json_set(payloadJSON,
                '$.transcript.endedAt', COALESCE(json_extract(payloadJSON, '$.transcript.endedAt'), json_extract(payloadJSON, '$.transcript.completedAt'))),
                '$.transcript.status', '$.transcript.completedAt')
            WHERE entity = 'transcript' AND json_valid(payloadJSON) AND json_type(payloadJSON, '$.transcript') = 'object';
            """)
        }
    }
}
