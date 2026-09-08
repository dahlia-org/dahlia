import DahliaRuntimeSupport
import Foundation
import GRDB

enum TranscriptVersionMigration {
    static func migrate(in db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS transcripts (
            meetingId TEXT PRIMARY KEY NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            sessionId TEXT,
            infoJSON TEXT NOT NULL
        );
        """)
        guard try db.tableExists("transcript_segments"), try db.tableExists("meetings") else { return }
        let meetings = try UUID.fetchAll(db, sql: "SELECT DISTINCT s.meetingId FROM transcript_segments s JOIN meetings m ON m.id = s.meetingId")
        for meetingId in meetings {
            let info = TranscriptInfo(id: .v7(), status: "completed", startedAt: nil, completedAt: nil, metadata: nil)
            try TranscriptRecord(meetingId: meetingId, info: info).insert(db, onConflict: .ignore)
        }

        // Only Desktop has existing data. Fold old queued deltas into a full, immutable upload,
        // retaining the latest local body and every unrelated operation in the same transactions.
        guard try db.tableExists("sync_operations") else { return }
        let pending = try UUID.fetchAll(db, sql: "SELECT DISTINCT entityId FROM sync_operations WHERE entity = 'transcript'")
        for meetingId in pending {
            let rows = try Row.fetchAll(db, sql: """
            SELECT o.id, o.transactionId, o.baseRevision FROM sync_operations o
            JOIN sync_transactions t ON t.id = o.transactionId
            WHERE o.entity = 'transcript' AND o.entityId = ? ORDER BY t.sequence, o.position
            """, arguments: [meetingId])
            guard let last = rows.last else { continue }
            if try MeetingRecord.fetchOne(db, key: meetingId) == nil {
                continue
            }
            let missing = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM transcript_segments s LEFT JOIN transcript_segment_bodies b ON b.segmentId = s.id
            WHERE s.meetingId = ? AND s.isConfirmed = 1 AND b.segmentId IS NULL
            """, arguments: [meetingId]) ?? 0
            let unmatchedPending = try Int.fetchOne(db, sql: """
            WITH latest AS (
                SELECT p.segmentId, p.action, p.text,
                    row_number() OVER (PARTITION BY p.segmentId ORDER BY t.sequence DESC, o.position DESC, p.position DESC) AS position
                FROM sync_transcript_patch_items p JOIN sync_operations o ON o.id = p.operationId
                JOIN sync_transactions t ON t.id = o.transactionId
                WHERE o.entity = 'transcript' AND o.entityId = ?
            )
            SELECT count(*) FROM latest p LEFT JOIN transcript_segment_bodies b ON b.segmentId = p.segmentId
            WHERE p.position = 1 AND p.action = 'upsert' AND (b.segmentId IS NULL OR b.text <> p.text)
            """, arguments: [meetingId]) ?? 0
            if missing > 0 || unmatchedPending > 0 {
                // Preserve the original queued bytes when a damaged/partial working copy cannot
                // provide a complete replacement. Never publish a truncated transcript.
                for row in rows {
                    try db.execute(
                        sql: "UPDATE sync_transactions SET blockedReason = 'validation', serverResponseJSON = ? WHERE id = ?",
                        arguments: ["{\"error\":\"transcript_content_incomplete\"}", row["transactionId"] as UUID]
                    )
                }
                continue
            }
            let info = try TranscriptRecord.current(meetingId, in: db)
                ?? TranscriptInfo(id: .v7(), status: "completed", startedAt: nil, completedAt: nil, metadata: nil)
            try TranscriptRecord(meetingId: meetingId, info: info).save(db)
            let lastId: UUID = last["id"]
            for row in rows {
                let id: UUID = row["id"]
                try db.execute(sql: "DELETE FROM sync_transcript_patch_items WHERE operationId = ?", arguments: [id])
                if id != lastId { try db.execute(sql: "DELETE FROM sync_operations WHERE id = ?", arguments: [id]) }
            }
            let payload = try String(decoding: SyncJSON.encoder.encode(TranscriptMutation(info: info, mode: "replace")), as: UTF8.self)
            let firstBase: Int? = rows.first?["baseRevision"]
            try db.execute(
                sql: "UPDATE sync_operations SET payloadJSON = ?, baseRevision = ? WHERE id = ?",
                arguments: [payload, firstBase ?? 0, lastId]
            )
            try TranscriptRecord.copySnapshot(meetingId: meetingId, operationId: lastId, in: db)
        }
        try db
            .execute(sql: "DELETE FROM sync_transactions WHERE NOT EXISTS (SELECT 1 FROM sync_operations WHERE transactionId = sync_transactions.id)")
    }
}
