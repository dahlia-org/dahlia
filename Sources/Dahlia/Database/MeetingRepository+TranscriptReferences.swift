import Foundation
import GRDB

extension MeetingRepository {
    private struct TranscriptReferenceTarget {
        let sessionID: UUID?
        let date: Date
    }

    nonisolated func fetchTranscriptReferencePage(
        forMeetingId meetingId: UUID,
        time: String,
        tolerance: TimeInterval,
        limit: Int
    ) throws -> TranscriptReferencePage? {
        guard let elapsedSeconds = TranscriptReferenceTime.seconds(from: time),
              tolerance >= 0,
              limit > 0 else { return nil }

        return try dbQueue.read { db in
            guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId) else { return nil }
            let sessions = try RecordingSessionRecord
                .filter(Column("meetingId") == meetingId)
                .order(Column("offsetSeconds").asc, Column("startedAt").asc)
                .fetchAll(db)
            let candidateSessions = sessions.filter {
                sessionMayContain(
                    elapsedSeconds: elapsedSeconds,
                    tolerance: tolerance,
                    session: $0
                )
            }
            let sessionByID = Dictionary(uniqueKeysWithValues: candidateSessions.map { ($0.id, $0) })
            let targets = candidateSessions.map { session in
                TranscriptReferenceTarget(
                    sessionID: session.id,
                    date: session.startedAt.addingTimeInterval(elapsedSeconds - session.offsetSeconds)
                )
            } + [TranscriptReferenceTarget(
                sessionID: nil,
                date: meeting.createdAt.addingTimeInterval(elapsedSeconds)
            )]
            let candidates = try referenceCandidates(
                meetingId: meetingId,
                targets: targets,
                tolerance: tolerance,
                in: db
            )
            let rankedCandidates = candidates.map { candidate in
                let rank = referenceRank(
                    candidate,
                    elapsedSeconds: elapsedSeconds,
                    meetingStart: meeting.createdAt,
                    sessions: sessionByID
                )
                return (segment: candidate, rank: rank)
            }
            guard let target = rankedCandidates.min(by: { lhs, rhs in
                if lhs.rank.distance != rhs.rank.distance { return lhs.rank.distance < rhs.rank.distance }
                if lhs.rank.start != rhs.rank.start { return lhs.rank.start < rhs.rank.start }
                return lhs.segment.id.uuidString < rhs.segment.id.uuidString
            }), target.rank.distance <= tolerance else { return nil }

            let page = try transcriptPage(around: target.segment, meetingId: meetingId, limit: limit, in: db)
            return TranscriptReferencePage(targetSegmentID: target.segment.id, page: page)
        }
    }

    private nonisolated func referenceCandidates(
        meetingId: UUID,
        targets: [TranscriptReferenceTarget],
        tolerance: TimeInterval,
        in db: Database
    ) throws -> [TranscriptSegmentRecord] {
        let targetPredicates = Array(repeating: """
        (sessionId IS ? AND startTime <= ? AND COALESCE(endTime, startTime) >= ?)
        """, count: targets.count).joined(separator: " OR ")
        var arguments: StatementArguments = [meetingId]
        for target in targets {
            arguments += [
                target.sessionID,
                target.date.addingTimeInterval(tolerance),
                target.date.addingTimeInterval(-tolerance),
            ]
        }
        return try TranscriptSegmentRecord.fetchAll(
            db,
            sql: """
            SELECT * FROM (
                SELECT transcript_segments.*,
                       ROW_NUMBER() OVER (PARTITION BY sessionId ORDER BY startTime ASC, id ASC) AS candidateRank
                FROM transcript_segments
                WHERE meetingId = ? AND isConfirmed = 1
                  AND (\(targetPredicates))
            )
            WHERE candidateRank <= 32
            """,
            arguments: arguments
        )
    }

    private nonisolated func sessionMayContain(
        elapsedSeconds: TimeInterval,
        tolerance: TimeInterval,
        session: RecordingSessionRecord
    ) -> Bool {
        guard elapsedSeconds >= session.offsetSeconds - tolerance else { return false }
        guard let duration = session.duration
            ?? session.endedAt.map({ $0.timeIntervalSince(session.startedAt) }) else { return true }
        return elapsedSeconds <= session.offsetSeconds + max(0, duration) + tolerance
    }

    private nonisolated func referenceRank(
        _ segment: TranscriptSegmentRecord,
        elapsedSeconds: TimeInterval,
        meetingStart: Date,
        sessions: [UUID: RecordingSessionRecord]
    ) -> (distance: TimeInterval, start: TimeInterval) {
        let session = segment.sessionId.flatMap { sessions[$0] }
        let base = session?.startedAt ?? meetingStart
        let offset = session?.offsetSeconds ?? 0
        let start = offset + segment.startTime.timeIntervalSince(base)
        let end = offset + (segment.endTime ?? segment.startTime).timeIntervalSince(base)
        let distance: TimeInterval = if elapsedSeconds < start {
            start - elapsedSeconds
        } else if elapsedSeconds > end {
            elapsedSeconds - end
        } else {
            0
        }
        return (distance, start)
    }

    private nonisolated func transcriptPage(
        around target: TranscriptSegmentRecord,
        meetingId: UUID,
        limit: Int,
        in db: Database
    ) throws -> TranscriptPage {
        let beforeLimit = max(0, (limit - 1) / 2)
        let afterLimit = max(0, limit - beforeLimit - 1)
        let before = try TranscriptSegmentRecord.fetchAll(
            db,
            sql: """
            SELECT * FROM transcript_segments
            WHERE meetingId = ? AND isConfirmed = 1
              AND (startTime < ? OR (startTime = ? AND id < ?))
            ORDER BY startTime DESC, id DESC LIMIT ?
            """,
            arguments: [meetingId, target.startTime, target.startTime, target.id, beforeLimit]
        ).reversed()
        let after = try TranscriptSegmentRecord.fetchAll(
            db,
            sql: """
            SELECT * FROM transcript_segments
            WHERE meetingId = ? AND isConfirmed = 1
              AND (startTime > ? OR (startTime = ? AND id > ?))
            ORDER BY startTime ASC, id ASC LIMIT ?
            """,
            arguments: [meetingId, target.startTime, target.startTime, target.id, afterLimit]
        )
        let records = Array(before) + [target] + after
        let first = records.first ?? target
        let last = records.last ?? target
        let hasEarlier = try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(SELECT 1 FROM transcript_segments WHERE meetingId = ? AND isConfirmed = 1
              AND (startTime < ? OR (startTime = ? AND id < ?)))
            """,
            arguments: [meetingId, first.startTime, first.startTime, first.id]
        ) ?? false
        let hasLater = try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(SELECT 1 FROM transcript_segments WHERE meetingId = ? AND isConfirmed = 1
              AND (startTime > ? OR (startTime = ? AND id > ?)))
            """,
            arguments: [meetingId, last.startTime, last.startTime, last.id]
        ) ?? false
        return TranscriptPage(
            segments: records.map(TranscriptSegment.init(from:)),
            hasEarlier: hasEarlier,
            hasLater: hasLater
        )
    }
}
