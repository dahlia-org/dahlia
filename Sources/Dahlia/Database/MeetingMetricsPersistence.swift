import Foundation
import GRDB

enum MeetingMetricsPersistence {
    enum SaveOutcome: Sendable, Equatable {
        case saved
        case revisionChanged(Int64)
    }

    static func save(_ result: MeetingMetricsResult, dbQueue: DatabaseQueue) throws -> SaveOutcome {
        try dbQueue.write { db in
            let currentRevision = try MeetingTranscriptRevision.current(meetingId: result.meetingId, in: db)
            guard currentRevision == result.transcriptRevision else {
                return .revisionChanged(currentRevision)
            }
            try MeetingMetricsRecord(result).upsert(db)
            try MeetingSourceMetricsRecord
                .filter(Column("meetingId") == result.meetingId)
                .deleteAll(db)
            for row in result.sourceRows {
                try MeetingSourceMetricsRecord(row).insert(db)
            }
            return .saved
        }
    }
}
