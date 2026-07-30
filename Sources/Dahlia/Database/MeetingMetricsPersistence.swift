import Foundation
import GRDB

enum MeetingMetricsPersistence {
    enum SaveOutcome: Sendable, Equatable {
        case saved
        case revisionChanged(Int64)
        case meetingDeleted
    }

    static func load(meetingId: UUID, dbQueue: DatabaseQueue) async throws -> MeetingMetricsResult? {
        try await dbQueue.read { db in
            guard let currentRevision = try Int64.fetchOne(
                db,
                sql: "SELECT transcriptRevision FROM meetings WHERE id = ?",
                arguments: [meetingId]
            ), let record = try MeetingMetricsRecord.fetchOne(db, key: meetingId),
            record.metricsVersion == MeetingMetricsConstants.metricsVersion,
            record.transcriptRevision == currentRevision else {
                return nil
            }
            let sourceRows = try MeetingSourceMetricsRecord
                .filter(Column("meetingId") == meetingId)
                .fetchAll(db)
                .map(MeetingSourceMetricsRow.init)
            let hasMoreSegments = try Int.fetchOne(
                db,
                sql: """
                SELECT 1
                FROM transcript_segments
                WHERE meetingId = ? AND isConfirmed = 1
                ORDER BY startTime, id
                LIMIT 1 OFFSET ?
                """,
                arguments: [meetingId, MeetingMetricsConstants.maximumAnalyzedSegmentCount]
            ) != nil
            return MeetingMetricsResult(record, sourceRows: sourceRows, isPartialAnalysis: hasMoreSegments)
        }
    }

    static func save(_ result: MeetingMetricsResult, dbQueue: DatabaseQueue) async throws -> SaveOutcome {
        try await dbQueue.write { db in
            guard let currentRevision = try Int64.fetchOne(
                db,
                sql: "SELECT transcriptRevision FROM meetings WHERE id = ?",
                arguments: [result.meetingId]
            ) else {
                return .meetingDeleted
            }
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
