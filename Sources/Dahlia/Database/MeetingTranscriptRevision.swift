import Foundation
import GRDB

enum MeetingTranscriptRevision {
    static func bump(meetingId: UUID, in db: Database) throws {
        try db.execute(
            sql: "UPDATE meetings SET transcriptRevision = transcriptRevision + 1 WHERE id = ?",
            arguments: [meetingId]
        )
    }

    static func current(meetingId: UUID, in db: Database) throws -> Int64 {
        try Int64.fetchOne(
            db,
            sql: "SELECT transcriptRevision FROM meetings WHERE id = ?",
            arguments: [meetingId]
        ) ?? 0
    }
}
