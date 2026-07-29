import Foundation
import GRDB

actor MeetingMetricsWorker {
    enum Outcome: Sendable, Equatable {
        case saved(MeetingMetricsResult, MeetingMetricsInsightSet)
        case empty(revision: Int64)
        case revisionChanged(Int64)
    }

    private let dbQueue: DatabaseQueue
    private let rowReadHook: (@Sendable (Int) -> Void)?

    init(dbQueue: DatabaseQueue, rowReadHook: (@Sendable (Int) -> Void)? = nil) {
        self.dbQueue = dbQueue
        self.rowReadHook = rowReadHook
    }

    func analyze(meetingId: UUID) async throws -> Outcome {
        try Task.checkCancellation()
        let snapshot = try await dbQueue.read { db -> (Int64, MeetingMetricsResult?) in
            try Task.checkCancellation()
            let revision = try MeetingTranscriptRevision.current(meetingId: meetingId, in: db)
            var accumulator = MeetingMetricsAnalyzer.Accumulator(meetingId: meetingId, revision: revision)
            let cursor = try TranscriptSegmentRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("startTime").asc, Column("id").asc)
                .fetchCursor(db)
            var rowCount = 0
            while let record = try cursor.next() {
                rowCount += 1
                rowReadHook?(rowCount)
                if rowCount.isMultiple(of: MeetingMetricsConstants.cancellationCheckSegmentStride) {
                    try Task.checkCancellation()
                }
                accumulator.append(record)
            }
            try Task.checkCancellation()
            return (revision, accumulator.finish())
        }
        try Task.checkCancellation()
        guard let result = snapshot.1 else {
            return .empty(revision: snapshot.0)
        }
        switch try MeetingMetricsPersistence.save(result, dbQueue: dbQueue) {
        case .saved:
            return .saved(result, MeetingMetricsEvaluator.evaluate(result))
        case let .revisionChanged(revision):
            return .revisionChanged(revision)
        }
    }
}
