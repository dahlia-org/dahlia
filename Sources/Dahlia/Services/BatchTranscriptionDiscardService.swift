import Foundation
import GRDB

/// 復旧不能なバッチ録音を破棄し、文字起こし待ちの対象から外す。
enum BatchTranscriptionDiscardService {
    static func discardFailedSessionSafely(
        id: UUID,
        dbQueue: DatabaseQueue,
        managedRootURL: URL = BatchAudioStorage.managedRootURL
    ) async throws -> Bool {
        let hasSegmentedAudio = try await dbQueue.read { db in
            try RecordingAudioSegmentRecord
                .filter(Column("recordingSessionId") == id)
                .fetchCount(db) > 0
        }
        guard hasSegmentedAudio else { return false }
        let store = try RecordingAudioStore(dbQueue: dbQueue, managedRootURL: managedRootURL)
        try await store.requestPurge(sessionId: id, includeFailed: true)
        return try await dbQueue.write { db in
            guard var session = try RecordingSessionRecord.fetchOne(db, key: id),
                  session.transcriptionMode == .batch,
                  session.batchCompletedAt == nil,
                  session.batchDiscardedAt == nil,
                  session.batchLastError?.nilIfBlank != nil else { return false }
            let now = Date.now
            session.batchDiscardedAt = now
            session.batchLastError = nil
            session.batchFailureKind = nil
            session.updatedAt = now
            try session.update(db)
            _ = try TranscriptSegmentRecord
                .filter(Column("sessionId") == id)
                .deleteAll(db)
            return true
        }
    }
}
