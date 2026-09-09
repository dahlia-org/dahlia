import Foundation
import GRDB

/// Preserve speech timestamps; backfill historical generation times with the agreed meeting end proxy.
enum TranscriptActivityMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists("transcript_segments"), try db.tableExists("meetings") else { return }
        let columns = try Set(db.columns(in: "transcript_segments").map(\.name))
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
        try finishLegacyRealtimeSessions(in: db)
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
        }
    }

    static func finishLegacyRealtimeSessions(in db: Database) throws {
        let sessions = try RecordingSessionRecord.filter(Column("transcriptionMode") == "realtime")
            .filter(Column("endedAt") == nil).fetchAll(db)
        for session in sessions {
            let lastTranscriptDate = try Date.fetchOne(db, sql: """
            SELECT MAX(COALESCE(endedAt, startedAt)) FROM transcript_segments WHERE sessionId = ?
            """, arguments: [session.id])
            let duration = max(0, session.duration ?? (lastTranscriptDate ?? session.updatedAt).timeIntervalSince(session.startedAt))
            try db.execute(sql: "UPDATE recording_sessions SET endedAt = ?, duration = ? WHERE id = ?", arguments: [
                session.startedAt.addingTimeInterval(duration), duration, session.id,
            ])
        }
        for meetingId in Set(sessions.map(\.meetingId)) {
            try db.execute(sql: """
            UPDATE meetings SET duration = (SELECT SUM(duration) FROM recording_sessions WHERE meetingId = ?)
            WHERE id = ?
            """, arguments: [meetingId, meetingId])
        }
    }
}
