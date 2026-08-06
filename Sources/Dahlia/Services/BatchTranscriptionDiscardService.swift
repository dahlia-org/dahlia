import Foundation
import GRDB

/// 復旧不能なバッチ録音を破棄し、文字起こし待ちの対象から外す。
enum BatchTranscriptionDiscardService {
    static func discardUnprocessedSessionSafely(
        id: UUID,
        dbQueue: DatabaseQueue,
        speakerProfileRepository: MeetingRepository,
        managedRootURL: URL = BatchAudioStorage.managedRootURL
    ) async throws -> Bool {
        let store = try RecordingAudioStore(dbQueue: dbQueue, managedRootURL: managedRootURL)
        let cacheKeys = try await dbQueue.write { db -> Set<SpeakerProfileCacheKey>? in
            guard var session = try RecordingSessionRecord.fetchOne(db, key: id),
                  isDiscardable(session),
                  try RecordingAudioSegmentRecord
                  .filter(Column("recordingSessionId") == id)
                  .fetchCount(db) > 0 else { return nil }
            let now = Date.now
            let profileTargets = try MeetingRepository.speakerProfileTargets(meetingIds: [session.meetingId], in: db)
            session.batchDiscardedAt = now
            session.batchLastError = nil
            session.batchFailureKind = nil
            session.updatedAt = now
            try session.update(db)
            _ = try TranscriptSegmentRecord
                .filter(Column("sessionId") == id)
                .deleteAll(db)
            _ = try SpeakerAnalysisRecord
                .filter(Column("recordingSessionId") == id)
                .deleteAll(db)
            return try MeetingRepository.recomputeSpeakerProfiles(profileTargets, now: now, in: db)
        }
        guard let cacheKeys else { return false }
        speakerProfileRepository.invalidateSpeakerProfilesAfterCommit(cacheKeys)
        try await store.requestPurge(sessionId: id, includeFailed: true)
        return true
    }

    static func discardFailedSessionSafely(
        id: UUID,
        dbQueue: DatabaseQueue,
        speakerProfileRepository: MeetingRepository,
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
        let cacheKeys = try await dbQueue.write { db -> Set<SpeakerProfileCacheKey>? in
            guard var session = try RecordingSessionRecord.fetchOne(db, key: id),
                  session.transcriptionMode == .batch,
                  session.batchCompletedAt == nil,
                  session.batchDiscardedAt == nil,
                  session.batchLastError?.nilIfBlank != nil else { return nil }
            let now = Date.now
            let profileTargets = try MeetingRepository.speakerProfileTargets(meetingIds: [session.meetingId], in: db)
            session.batchDiscardedAt = now
            session.batchLastError = nil
            session.batchFailureKind = nil
            session.updatedAt = now
            try session.update(db)
            _ = try TranscriptSegmentRecord
                .filter(Column("sessionId") == id)
                .deleteAll(db)
            _ = try SpeakerAnalysisRecord
                .filter(Column("recordingSessionId") == id)
                .deleteAll(db)
            return try MeetingRepository.recomputeSpeakerProfiles(profileTargets, now: now, in: db)
        }
        guard let cacheKeys else { return false }
        speakerProfileRepository.invalidateSpeakerProfilesAfterCommit(cacheKeys)
        return true
    }

    private static func isDiscardable(_ session: RecordingSessionRecord) -> Bool {
        guard session.transcriptionMode == .batch,
              session.endedAt != nil,
              session.batchCompletedAt == nil,
              session.batchDiscardedAt == nil else { return false }
        return session.batchLastError?.nilIfBlank != nil
            || (session.batchLastAttemptAt == nil && session.batchAttemptCount == 0)
    }
}
