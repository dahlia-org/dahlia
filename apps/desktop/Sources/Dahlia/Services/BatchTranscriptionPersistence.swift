import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

/// Publish a complete new transcript and its generation facts in one local transaction.
enum BatchTranscriptionPersistence {
    static func validateReplacementCoverage(meetingID: UUID, sessions: [RecordingSessionRecord], in db: Database) throws {
        let ids = sessions.map(\.id)
        let uncovered = try TranscriptSegmentRecord.filter(Column("meetingId") == meetingID)
            .filter(Column("sessionId") == nil || !ids.contains(Column("sessionId"))).fetchCount(db)
        guard uncovered > 0 else { return }
        guard let metadata = try TranscriptRecord.current(meetingID, in: db)?.metadata, !metadata.runs.isEmpty,
              let meeting = try MeetingRecord.fetchOne(db, key: meetingID),
              let workspace = try WorkspaceRecord.fetchOne(db, key: meeting.workspaceId)
        else { throw TranscriptVersionError.fullTranscriptionUnavailable }
        let archives = try RecordingArchiveRecord.filter(Column("meetingId") == meetingID)
            .filter(ids.contains(Column("sessionId"))).fetchAll(db)
        for run in metadata.runs {
            if run.generatedBy == "desktop", let sessionID = run.recordingSessionId, ids.contains(sessionID) { continue }
            guard run.generatedBy == "server", let inputs = run.audioInputs, !inputs.isEmpty else {
                throw TranscriptVersionError.fullTranscriptionUnavailable
            }
            for input in inputs {
                guard let archive = archives.first(where: {
                    $0.number == input.recordingNumber && $0.workspaceId == workspace.id && $0.connectionId == workspace.accountConnectionId
                }), try archive.audio[input.source]?.checksum == input.checksum else {
                    throw TranscriptVersionError.fullTranscriptionUnavailable
                }
            }
        }
    }

    static func complete(
        sessionId: UUID,
        meetingId: UUID,
        records: [TranscriptContent],
        completedAt: Date,
        dbQueue: DatabaseQueue,
        replacingMeeting: Bool = false,
        expectedTranscriptId: UUID? = nil,
        expectedSessions: [RecordingSessionRecord]? = nil,
        runs: [TranscriptMetadata.Run] = []
    ) throws {
        try dbQueue.write { db in
            guard let session = try RecordingSessionRecord.fetchOne(db, key: sessionId),
                  session.meetingId == meetingId,
                  let meeting = try MeetingRecord.fetchOne(db, key: meetingId) else {
                throw CocoaError(.fileNoSuchFile)
            }
            guard session.batchDiscardedAt == nil,
                  session.batchCompletedAt == nil || session.isBatchRetranscriptionPending else {
                throw CancellationError()
            }
            guard try RecordingProcessing.load(sessionID: sessionId, in: db)?.stage != .cancelled else { throw CancellationError() }
            let previous = try TranscriptRecord.current(meetingId, in: db)
            guard previous?.id == expectedTranscriptId else { throw TextContentError.changed }
            if let expectedSessions {
                for expected in expectedSessions {
                    guard var current = try RecordingSessionRecord.fetchOne(db, key: expected.id) else { throw CancellationError() }
                    let expectedProcessing = try expected.processingJSON.map {
                        try JSONDecoder().decode(RecordingProcessing.self, from: Data($0.utf8))
                    }
                    let currentProcessing = try RecordingProcessing.load(sessionID: expected.id, in: db)
                    guard currentProcessing?.id == expectedProcessing?.id,
                          currentProcessing?.stage != .cancelled || expectedProcessing?.stage == .cancelled else { throw CancellationError() }
                    current.processingJSON = expected.processingJSON
                    guard current == expected else { throw CancellationError() }
                }
            }
            let sessions = expectedSessions ?? [session]
            let ids = Set(sessions.map(\.id))
            guard records.allSatisfy({ $0.meetingId == meetingId && $0.sessionId.map(ids.contains) == true && $0.isConfirmed }) else {
                throw TextContentError.integrityFailure
            }
            if replacingMeeting {
                try validateReplacementCoverage(meetingID: meetingId, sessions: sessions, in: db)
                guard try RecordingSessionRecord.filter(Column("meetingId") == meetingId)
                    .filter(Column("endedAt") == nil).fetchCount(db) == 0,
                    try RecordingSessionRecord.filter(Column("meetingId") == meetingId)
                    .filter(Column("batchDiscardedAt") == nil).fetchCount(db) == sessions.count else { throw TextContentError.changed }
                _ = try TranscriptSegmentRecord.filter(Column("meetingId") == meetingId).deleteAll(db)
            } else {
                _ = try TranscriptSegmentRecord.filter(ids.contains(Column("sessionId"))).deleteAll(db)
            }
            for record in records {
                try record.insert(db)
            }
            let persistedCompletedAt = max(completedAt, session.batchLastAttemptAt ?? completedAt)
            for completed in sessions {
                try db.execute(sql: """
                UPDATE recording_sessions SET batchCompletedAt = ?, batchLastError = NULL,
                    batchFailureKind = NULL, updatedAt = ? WHERE id = ?
                """, arguments: [persistedCompletedAt, persistedCompletedAt, completed.id])
            }
            try db.execute(
                sql: "UPDATE meetings SET status = ?, updatedAt = ? WHERE id = ?",
                arguments: [MeetingStatus.ready.rawValue, persistedCompletedAt, meetingId]
            )
            let executionRuns = runs.isEmpty ? [TranscriptMetadata.Run(
                startedAt: session.batchLastAttemptAt,
                completedAt: persistedCompletedAt,
                language: .init(
                    mode: session.batchLanguageDetectionMode == .automatic ? "auto" : "fixed",
                    locales: session
                        .batchSelectedLocaleIdentifier
                        .map { [$0] } ?? []
                ),
                recordingSessionId: session.id
            )] : runs
            let metadata = TranscriptMetadata(
                provider: "apple",
                model: "apple-speech",
                runs: (!replacingMeeting && previous?.metadata?.usesAppleModel("apple-speech") == true ? previous?
                    .metadata?.runs ?? [] : []) + executionRuns
            )
            let info = TranscriptInfo(
                id: .v7(),
                startedAt: executionRuns.first?.startedAt,
                endedAt: persistedCompletedAt,
                metadata: metadata
            )
            try TranscriptRecord(meetingId: meetingId, info: info).save(db)
            try TranscriptRecord.enqueueSnapshot(meetingId: meetingId, info: info, in: db)
            guard let updated = try MeetingRecord.fetchOne(db, key: meetingId) else { throw CocoaError(.fileNoSuchFile) }
            try SyncTransactionRecorder.record(
                workspaceId: meeting.workspaceId,
                operations: [SyncInitialSnapshotBuilder.meetingOperation(updated, action: .update, in: db)],
                in: db
            )
        }
    }
}
