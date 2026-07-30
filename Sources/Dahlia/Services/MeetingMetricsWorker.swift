import Foundation
import GRDB

actor MeetingMetricsWorker {
    enum Outcome: Sendable, Equatable {
        case saved(MeetingMetricsResult, MeetingMetricsInsightSet)
        case empty(revision: Int64)
        case revisionChanged(Int64)
    }

    private struct PageCursor: Sendable {
        let startTime: Date
        let id: UUID
    }

    private let dbQueue: DatabaseQueue
    private let rowReadHook: (@Sendable (Int) -> Void)?

    init(dbQueue: DatabaseQueue, rowReadHook: (@Sendable (Int) -> Void)? = nil) {
        self.dbQueue = dbQueue
        self.rowReadHook = rowReadHook
    }

    func analyze(meetingId: UUID, ignoringCache: Bool = false) async throws -> Outcome {
        try Task.checkCancellation()
        if !ignoringCache,
           let cached = try await MeetingMetricsPersistence.load(meetingId: meetingId, dbQueue: dbQueue) {
            return .saved(cached, MeetingMetricsEvaluator.evaluate(cached))
        }

        let snapshot = try await analyzeTranscript(meetingId: meetingId)
        guard let result = snapshot.result else {
            return .empty(revision: snapshot.revision)
        }
        switch try await MeetingMetricsPersistence.save(result, dbQueue: dbQueue) {
        case .saved:
            return .saved(result, MeetingMetricsEvaluator.evaluate(result))
        case let .revisionChanged(currentRevision):
            return .revisionChanged(currentRevision)
        case .meetingDeleted:
            return .empty(revision: snapshot.revision)
        }
    }

    private func analyzeTranscript(meetingId: UUID) async throws -> (revision: Int64, result: MeetingMetricsResult?) {
        let revision = try await dbQueue.read { db in
            try MeetingTranscriptRevision.current(meetingId: meetingId, in: db)
        }
        var accumulator = MeetingMetricsAnalyzer.Accumulator(meetingId: meetingId, revision: revision)
        var cursor: PageCursor?
        var analyzedSegmentCount = 0
        var rowCount = 0

        while true {
            try Task.checkCancellation()
            let remaining = MeetingMetricsConstants.maximumAnalyzedSegmentCount - analyzedSegmentCount
            let pageLimit = min(MeetingMetricsConstants.segmentReadChunkSize, max(remaining + 1, 1))
            let page = try await readPage(meetingId: meetingId, after: cursor, limit: pageLimit)
            guard !page.isEmpty else { break }

            let acceptedCount = min(page.count, remaining)
            for record in page.prefix(acceptedCount) {
                rowCount += 1
                rowReadHook?(rowCount)
                if rowCount.isMultiple(of: MeetingMetricsConstants.cancellationCheckSegmentStride) {
                    try Task.checkCancellation()
                }
                accumulator.append(record)
            }
            analyzedSegmentCount += acceptedCount

            if page.count > acceptedCount {
                accumulator.markPartialAnalysis()
                break
            }
            guard page.count == pageLimit, let last = page.last else { break }
            cursor = PageCursor(startTime: last.startTime, id: last.id)
        }

        try Task.checkCancellation()
        return (revision, accumulator.finish())
    }

    private func readPage(
        meetingId: UUID,
        after cursor: PageCursor?,
        limit: Int
    ) async throws -> [MeetingMetricsAnalyzer.Segment] {
        try await dbQueue.read { db in
            var arguments: StatementArguments = [meetingId]
            let cursorClause: String
            if let cursor {
                cursorClause = "AND (startTime > ? OR (startTime = ? AND id > ?))"
                arguments += [cursor.startTime, cursor.startTime, cursor.id]
            } else {
                cursorClause = ""
            }
            arguments += [limit]
            return try MeetingMetricsAnalyzer.Segment.fetchAll(
                db,
                sql: """
                SELECT id, startTime, endTime, text, speakerLabel
                FROM transcript_segments
                WHERE meetingId = ? AND isConfirmed = 1
                \(cursorClause)
                ORDER BY startTime, id
                LIMIT ?
                """,
                arguments: arguments
            )
        }
    }
}
