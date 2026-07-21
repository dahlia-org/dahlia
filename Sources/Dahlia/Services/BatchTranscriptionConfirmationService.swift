import Foundation
import GRDB

/// 同じミーティングの未確認バッチ録音を確定し、再起動後も自動復旧できる状態へ原子的に移す。
enum BatchTranscriptionConfirmationService {
    struct Result: Equatable {
        let meetingId: UUID
        let sessionIds: [UUID]
    }

    private struct PersistenceOptions {
        let languageDetectionMode: BatchLanguageDetectionMode
        let selectedLocaleIdentifier: String?
        let automaticLanguageCandidatesJSON: String?
        let retainAudioAfterBatch: Bool
    }

    static func confirm(
        sessionId: UUID,
        languageSelection: BatchTranscriptionLanguageSelection,
        automaticLanguageCandidates: BatchLanguageDetectionCandidateSnapshot?,
        retainAudioAfterBatch: Bool,
        dbQueue: DatabaseQueue
    ) async throws -> Result {
        let persistenceOptions = try persistenceOptions(
            languageSelection: languageSelection,
            automaticLanguageCandidates: automaticLanguageCandidates,
            retainAudioAfterBatch: retainAudioAfterBatch
        )

        return try await dbQueue.write { db in
            let session = try validSession(id: sessionId, db: db)
            let sessions: [RecordingSessionRecord]
            if session.batchLastError?.nilIfBlank != nil {
                sessions = [session]
            } else {
                guard session.batchLastError == nil,
                      session.batchLastAttemptAt == nil,
                      session.batchAttemptCount == 0 else {
                    throw CocoaError(.fileNoSuchFile)
                }
                sessions = try unconfirmedSessions(meetingId: session.meetingId, db: db)
            }
            let confirmedAt = Date.now
            for unconfirmedSession in sessions {
                try requireAudioRanges(sessionId: unconfirmedSession.id, db: db)
                if let selectedLocaleIdentifier = persistenceOptions.selectedLocaleIdentifier {
                    try updateSingleRecordedLocale(
                        sessionId: unconfirmedSession.id,
                        localeIdentifier: selectedLocaleIdentifier,
                        updatedAt: confirmedAt,
                        db: db
                    )
                }
                try markConfirmed(
                    sessionId: unconfirmedSession.id,
                    options: persistenceOptions,
                    confirmedAt: confirmedAt,
                    db: db
                )
            }
            return Result(meetingId: session.meetingId, sessionIds: sessions.map(\.id))
        }
    }
}

extension BatchTranscriptionConfirmationService {
    /// Requeues completed sessions without removing their last successful transcript.
    static func confirmRetranscription(
        sessionIds: [UUID],
        languageSelection: BatchTranscriptionLanguageSelection,
        automaticLanguageCandidates: BatchLanguageDetectionCandidateSnapshot?,
        retainAudioAfterBatch: Bool,
        dbQueue: DatabaseQueue
    ) async throws -> Result {
        let options = try persistenceOptions(
            languageSelection: languageSelection,
            automaticLanguageCandidates: automaticLanguageCandidates,
            retainAudioAfterBatch: retainAudioAfterBatch
        )

        return try await dbQueue.write { db in
            let uniqueSessionIds = Array(Set(sessionIds))
            guard !uniqueSessionIds.isEmpty else { throw CocoaError(.fileNoSuchFile) }
            let sessions = try RecordingSessionRecord
                .filter(uniqueSessionIds.contains(Column("id")))
                .order(Column("startedAt").asc)
                .fetchAll(db)
            guard sessions.count == uniqueSessionIds.count,
                  let meetingId = sessions.first?.meetingId,
                  sessions.allSatisfy({ session in
                      session.meetingId == meetingId
                          && session.transcriptionMode == .batch
                          && session.endedAt != nil
                          && session.batchCompletedAt != nil
                          && session.batchDiscardedAt == nil
                          && (session.retainAudioAfterBatch || session.isBatchRetranscriptionPending)
                  }) else {
                throw CocoaError(.fileNoSuchFile)
            }

            guard let latestCompletion = sessions.compactMap(\.batchCompletedAt).max() else {
                throw CocoaError(.fileNoSuchFile)
            }
            // The timestamp ordering is also the persisted pending marker. Keep it valid if the
            // system clock moved backwards after the previous transcription completed.
            let confirmedAt = max(Date.now, latestCompletion.addingTimeInterval(0.001))
            for session in sessions {
                try requireTranscribableAudio(sessionId: session.id, db: db)
                if let selectedLocaleIdentifier = options.selectedLocaleIdentifier {
                    try updateSingleRecordedLocale(
                        sessionId: session.id,
                        localeIdentifier: selectedLocaleIdentifier,
                        updatedAt: confirmedAt,
                        db: db
                    )
                }
                try markRetranscriptionConfirmed(
                    sessionId: session.id,
                    options: options,
                    confirmedAt: confirmedAt,
                    db: db
                )
            }
            return Result(meetingId: meetingId, sessionIds: sessions.map(\.id))
        }
    }

    /// Stops a failed retranscription and restores the last successful transcript as the active result.
    static func cancelRetranscription(sessionIds: [UUID], dbQueue: DatabaseQueue) async throws -> UUID {
        try await dbQueue.write { db in
            let uniqueSessionIds = Array(Set(sessionIds))
            guard !uniqueSessionIds.isEmpty else { throw CocoaError(.fileNoSuchFile) }
            let sessions = try RecordingSessionRecord
                .filter(uniqueSessionIds.contains(Column("id")))
                .fetchAll(db)
            guard sessions.count == uniqueSessionIds.count,
                  let meetingId = sessions.first?.meetingId,
                  sessions.allSatisfy({ $0.meetingId == meetingId && $0.isBatchRetranscriptionPending }) else {
                throw CocoaError(.fileNoSuchFile)
            }

            let cancelledAt = Date.now
            var arguments: StatementArguments = [RecordingAudioRetentionPolicy.keepInApp.rawValue, cancelledAt]
            arguments += StatementArguments(uniqueSessionIds)
            try db.execute(
                sql: """
                UPDATE recording_sessions
                SET retainAudioAfterBatch = 1, audioRetentionPolicy = ?,
                    batchLastAttemptAt = batchCompletedAt, batchAttemptCount = 0,
                    batchLastError = NULL, batchFailureKind = NULL, updatedAt = ?
                WHERE id IN (\(databasePlaceholders(count: uniqueSessionIds.count)))
                """,
                arguments: arguments
            )
            guard db.changesCount == uniqueSessionIds.count else { throw CocoaError(.fileNoSuchFile) }
            return meetingId
        }
    }

    private static func selectedLocaleIdentifier(
        from selection: BatchTranscriptionLanguageSelection
    ) throws -> String? {
        guard case let .manual(localeIdentifier) = selection else { return nil }
        let normalized = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        return normalized
    }

    private static func persistenceOptions(
        languageSelection: BatchTranscriptionLanguageSelection,
        automaticLanguageCandidates: BatchLanguageDetectionCandidateSnapshot?,
        retainAudioAfterBatch: Bool
    ) throws -> PersistenceOptions {
        try PersistenceOptions(
            languageDetectionMode: languageSelection.detectionMode,
            selectedLocaleIdentifier: selectedLocaleIdentifier(from: languageSelection),
            automaticLanguageCandidatesJSON: automaticLanguageCandidatesJSON(
                from: languageSelection,
                candidates: automaticLanguageCandidates
            ),
            retainAudioAfterBatch: retainAudioAfterBatch
        )
    }

    private static func automaticLanguageCandidatesJSON(
        from selection: BatchTranscriptionLanguageSelection,
        candidates: BatchLanguageDetectionCandidateSnapshot?
    ) throws -> String? {
        guard selection == .automatic else { return nil }
        guard let candidates, !candidates.languageIdentifiers.isEmpty else {
            throw BatchSpeechTranscriberError.noAutomaticLanguageCandidates
        }
        return try candidates.encoded()
    }

    private static func validSession(id: UUID, db: Database) throws -> RecordingSessionRecord {
        guard let session = try RecordingSessionRecord.fetchOne(db, key: id),
              session.transcriptionMode == .batch,
              session.endedAt != nil,
              session.batchCompletedAt == nil,
              session.batchDiscardedAt == nil else {
            throw CocoaError(.fileNoSuchFile)
        }
        return session
    }

    private static func unconfirmedSessions(meetingId: UUID, db: Database) throws -> [RecordingSessionRecord] {
        try RecordingSessionRecord
            .filter(Column("meetingId") == meetingId)
            .filter(Column("transcriptionMode") == TranscriptionMode.batch.rawValue)
            .filter(Column("endedAt") != nil)
            .filter(Column("batchCompletedAt") == nil)
            .filter(Column("batchDiscardedAt") == nil)
            .filter(Column("batchLastError") == nil)
            .filter(Column("batchLastAttemptAt") == nil)
            .filter(Column("batchAttemptCount") == 0)
            .filter(sql: """
            EXISTS (
                SELECT 1 FROM recording_audio_segments
                WHERE recording_audio_segments.recordingSessionId = recording_sessions.id
            )
            """)
            .order(Column("startedAt").asc)
            .fetchAll(db)
    }

    private static func requireAudioRanges(sessionId: UUID, db: Database) throws {
        let rangeCount = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM recording_audio_segment_ranges
            WHERE audioSegmentId IN (
                SELECT id FROM recording_audio_segments WHERE recordingSessionId = ?
            )
            """,
            arguments: [sessionId]
        ) ?? 0
        guard rangeCount > 0 else {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    private static func requireTranscribableAudio(sessionId: UUID, db: Database) throws {
        let segmentCount = try RecordingAudioSegmentRecord
            .filter(Column("recordingSessionId") == sessionId)
            .fetchCount(db)
        let transcribableSegmentCount = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM recording_audio_segments AS segments
            WHERE segments.recordingSessionId = ?
              AND segments.state = ?
              AND segments.purgedAt IS NULL
              AND EXISTS (
                  SELECT 1 FROM recording_audio_segment_ranges AS ranges
                  WHERE ranges.audioSegmentId = segments.id
              )
            """,
            arguments: [sessionId, RecordingAudioSegmentState.ready.rawValue]
        ) ?? 0
        guard segmentCount > 0, transcribableSegmentCount == segmentCount else {
            throw CocoaError(.fileNoSuchFile)
        }
    }

    private static func databasePlaceholders(count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    private static func updateSingleRecordedLocale(
        sessionId: UUID,
        localeIdentifier: String,
        updatedAt: Date,
        db: Database
    ) throws {
        let recordedLocales = try String.fetchAll(
            db,
            sql: """
            SELECT DISTINCT localeIdentifier
            FROM recording_audio_segment_ranges
            WHERE audioSegmentId IN (
                SELECT id FROM recording_audio_segments WHERE recordingSessionId = ?
            )
            """,
            arguments: [sessionId]
        )
        // 録音中に明示的に言語を切り替えた複数localeのrangeは保持する。
        guard recordedLocales.count <= 1 else { return }
        try db.execute(
            sql: """
            UPDATE recording_audio_segment_ranges
            SET localeIdentifier = ?, updatedAt = ?
            WHERE audioSegmentId IN (
                SELECT id FROM recording_audio_segments WHERE recordingSessionId = ?
            )
            """,
            arguments: [localeIdentifier, updatedAt, sessionId]
        )
    }

    private static func markConfirmed(
        sessionId: UUID,
        options: PersistenceOptions,
        confirmedAt: Date,
        db: Database
    ) throws {
        // 試行時刻を確認済みマーカーとして先に保存する。処理開始時に実際の開始時刻で上書きされる。
        try db.execute(
            sql: """
            UPDATE recording_sessions
            SET retainAudioAfterBatch = ?, audioRetentionPolicy = ?,
                batchLanguageDetectionMode = ?, batchSelectedLocaleIdentifier = ?,
                batchAutomaticLanguageCandidatesJSON = ?, batchLastAttemptAt = ?,
                batchLastError = NULL, batchFailureKind = NULL, updatedAt = ?
            WHERE id = ?
            """,
            arguments: [
                options.retainAudioAfterBatch,
                options.retainAudioAfterBatch
                    ? RecordingAudioRetentionPolicy.keepInApp.rawValue
                    : RecordingAudioRetentionPolicy.deleteAfterTranscription.rawValue,
                options.languageDetectionMode.rawValue,
                options.selectedLocaleIdentifier,
                options.automaticLanguageCandidatesJSON,
                confirmedAt,
                confirmedAt,
                sessionId,
            ]
        )
    }

    private static func markRetranscriptionConfirmed(
        sessionId: UUID,
        options: PersistenceOptions,
        confirmedAt: Date,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE recording_sessions
            SET retainAudioAfterBatch = ?, audioRetentionPolicy = ?,
                batchLanguageDetectionMode = ?, batchSelectedLocaleIdentifier = ?,
                batchAutomaticLanguageCandidatesJSON = ?, batchLastAttemptAt = ?,
                batchAttemptCount = 0, batchLastError = NULL, batchFailureKind = NULL, updatedAt = ?
            WHERE id = ?
              AND batchCompletedAt IS NOT NULL
              AND batchDiscardedAt IS NULL
            """,
            arguments: [
                options.retainAudioAfterBatch,
                options.retainAudioAfterBatch
                    ? RecordingAudioRetentionPolicy.keepInApp.rawValue
                    : RecordingAudioRetentionPolicy.deleteAfterTranscription.rawValue,
                options.languageDetectionMode.rawValue,
                options.selectedLocaleIdentifier,
                options.automaticLanguageCandidatesJSON,
                confirmedAt,
                confirmedAt,
                sessionId,
            ]
        )
        guard db.changesCount == 1 else { throw CocoaError(.fileNoSuchFile) }
    }
}
