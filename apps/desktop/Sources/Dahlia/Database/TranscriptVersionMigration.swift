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
            let info = TranscriptInfo(id: .v7(), startedAt: nil, endedAt: nil, metadata: nil)
            try TranscriptRecord(meetingId: meetingId, info: info).insert(db, onConflict: .ignore)
        }
    }
}
