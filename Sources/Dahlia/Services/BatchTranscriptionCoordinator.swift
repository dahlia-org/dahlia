import Foundation
import GRDB

private struct BatchRecordingFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// 未完了のバッチセッションを直列実行し、成功結果だけをDBへ反映する。
actor BatchTranscriptionCoordinator {
    typealias StateHandler = @Sendable (BatchTranscriptionUpdate) async -> Void

    static let maximumAutomaticAttemptCount = 3

    private struct Job {
        let session: RecordingSessionRecord
        let meeting: MeetingRecord
        let vault: VaultRecord
        let projectName: String
    }

    private struct TranslationConfiguration {
        let isEnabled: Bool
        let targetLanguage: String
    }

    private let dbQueue: DatabaseQueue
    private let recordingAudioStore: RecordingAudioStore?
    private let translationService = TranscriptTranslationService()
    private let onStateChange: StateHandler
    private var pendingSessionIds: [UUID] = []
    private var runningSessionId: UUID?
    private var processorTask: Task<Void, Never>?

    init(
        dbQueue: DatabaseQueue,
        managedRootURL: URL = BatchAudioStorage.managedRootURL,
        onStateChange: @escaping StateHandler
    ) {
        self.dbQueue = dbQueue
        recordingAudioStore = try? RecordingAudioStore(
            dbQueue: dbQueue,
            managedRootURL: managedRootURL
        )
        self.onStateChange = onStateChange
    }

    func recoverAndEnqueue() async {
        _ = await recordingAudioStore?.reconcileStartup()
        let sessionIds = await (try? dbQueue.read { db in
            try RecordingSessionRecord
                .filter(Column("transcriptionMode") == TranscriptionMode.batch.rawValue)
                .filter(Column("batchCompletedAt") == nil)
                .filter(Column("batchDiscardedAt") == nil)
                .order(Column("startedAt").asc)
                .fetchAll(db)
                .filter(Self.shouldAutomaticallyRetry)
                .map(\.id)
        }) ?? []

        for sessionId in sessionIds {
            await enqueue(sessionId: sessionId)
        }
    }

    static func shouldAutomaticallyRetry(_ session: RecordingSessionRecord) -> Bool {
        guard session.transcriptionMode == .batch,
              session.batchCompletedAt == nil,
              session.batchDiscardedAt == nil else { return false }
        guard session.batchFailureKind != .recordingRecovery,
              session.batchFailureKind != .recordingAudioPermanent else { return false }
        guard session.batchLastAttemptAt != nil || session.batchLastError?.nilIfBlank != nil else {
            return false
        }
        guard session.batchLastError?.nilIfBlank != nil else { return true }
        return session.batchAttemptCount < maximumAutomaticAttemptCount
    }

    func confirmAndEnqueue(
        sessionId: UUID,
        localeIdentifier: String,
        retainAudioAfterBatch: Bool
    ) async throws {
        let result = try await BatchTranscriptionConfirmationService.confirm(
            sessionId: sessionId,
            localeIdentifier: localeIdentifier,
            retainAudioAfterBatch: retainAudioAfterBatch,
            dbQueue: dbQueue
        )
        for confirmedSessionId in result.sessionIds {
            await notify(meetingId: result.meetingId, state: .queued(sessionId: confirmedSessionId))
            await enqueue(sessionId: confirmedSessionId)
        }
    }

    func enqueue(sessionId: UUID) async {
        guard runningSessionId != sessionId, !pendingSessionIds.contains(sessionId) else { return }
        do {
            guard try await claimForQueue(sessionId: sessionId) else { return }
        } catch {
            ErrorReportingService.capture(error, context: ["source": "batchTranscriptionQueue"])
            return
        }
        pendingSessionIds.append(sessionId)
        guard processorTask == nil else { return }
        processorTask = Task { [weak self] in
            await self?.processQueue()
        }
    }

    func isRunning(sessionId: UUID) -> Bool {
        runningSessionId == sessionId
    }

    func recordRecordingFailure(sessionId: UUID, message: String) async {
        await persistFailure(sessionId: sessionId, message: message, kind: .recordingStorage)
        ErrorReportingService.capture(
            BatchRecordingFailure(message: message),
            context: ["source": "batchRecording"]
        )
    }

    private func processQueue() async {
        while !pendingSessionIds.isEmpty {
            let sessionId = pendingSessionIds.removeFirst()
            runningSessionId = sessionId
            do {
                try await markAttemptStarted(sessionId: sessionId)
                let meetingId = try meetingId(for: sessionId)
                await notify(meetingId: meetingId, state: .running(sessionId: sessionId))
                try await process(sessionId: sessionId)
                await notify(meetingId: meetingId, state: .completed(sessionId: sessionId))
            } catch is CancellationError {
                // The session was completed or explicitly discarded after it was queued.
            } catch {
                await recordFailure(sessionId: sessionId, error: error)
            }
            runningSessionId = nil
        }
        processorTask = nil
    }

    private func process(sessionId: UUID) async throws {
        let job = try fetchJob(sessionId: sessionId)
        let segments = try await transcribe(job: job)
        let records = segments.map { TranscriptSegmentRecord(from: $0, meetingId: job.meeting.id, defaultSessionId: job.session.id) }
        let completedAt = Date.now
        try BatchTranscriptionPersistence.complete(
            sessionId: job.session.id,
            meetingId: job.meeting.id,
            records: records,
            completedAt: completedAt,
            dbQueue: dbQueue
        )

        await performPostProcessing(for: job)
    }

    private func performPostProcessing(for job: Job) async {
        do {
            try exportTranscript(for: job)
        } catch {
            ErrorReportingService.capture(error, context: ["source": "batchTranscriptExport"])
        }
        guard !job.session.retainAudioAfterBatch,
              let recordingAudioStore else { return }
        do {
            // A failed tail is intentionally retained after partial recovery. Force-purging it
            // cannot be resumed safely if deletion is interrupted before its intent is persisted.
            let hasFailedSegments = try await recordingAudioStore.hasFailedSegments(sessionId: job.session.id)
            guard !hasFailedSegments else { return }
            try await recordingAudioStore.requestPurge(sessionId: job.session.id)
        } catch {
            ErrorReportingService.capture(error, context: ["source": "batchAudioPurge"])
        }
    }

    private func markAttemptStarted(sessionId: UUID) async throws {
        let attemptDate = Date.now
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE recording_sessions
                SET batchLastAttemptAt = ?, batchAttemptCount = batchAttemptCount + 1,
                    batchLastError = NULL, batchFailureKind = NULL, updatedAt = ?
                WHERE id = ?
                  AND batchCompletedAt IS NULL
                  AND batchDiscardedAt IS NULL
                """,
                arguments: [attemptDate, attemptDate, sessionId]
            )
            guard db.changesCount == 1 else { throw CancellationError() }
        }
    }

    private func claimForQueue(sessionId: UUID) async throws -> Bool {
        let now = Date.now
        return try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE recording_sessions
                SET batchLastAttemptAt = COALESCE(batchLastAttemptAt, ?),
                    batchLastError = NULL, batchFailureKind = NULL, updatedAt = ?
                WHERE id = ?
                  AND transcriptionMode = ?
                  AND batchCompletedAt IS NULL
                  AND batchDiscardedAt IS NULL
                """,
                arguments: [now, now, sessionId, TranscriptionMode.batch.rawValue]
            )
            return db.changesCount == 1
        }
    }

    private func transcribe(job: Job) async throws -> [TranscriptSegment] {
        let translationConfiguration = await MainActor.run {
            TranslationConfiguration(
                isEnabled: AppSettings.shared.transcriptTranslationEnabled,
                targetLanguage: AppSettings.shared.transcriptTranslationTargetLanguage
            )
        }

        guard let recordingAudioStore else {
            throw RecordingAudioStoreError.storageUnavailable
        }
        return try await recordingAudioStore.withVerifiedTranscribableSegments(sessionId: job.session.id) { verified in
            try await self.transcribe(
                verifiedSegments: verified,
                job: job,
                translationConfiguration: translationConfiguration
            )
        }
    }

    private func transcribe(
        verifiedSegments: [RecordingAudioStore.VerifiedSegment],
        job: Job,
        translationConfiguration: TranslationConfiguration
    ) async throws -> [TranscriptSegment] {
        var transcriptSegments: [TranscriptSegment] = []
        for verified in verifiedSegments {
            for range in verified.ranges {
                try await transcriptSegments.append(contentsOf: transcribe(
                    range: range,
                    segment: verified.segment,
                    audioURL: verified.url,
                    session: job.session,
                    translationConfiguration: translationConfiguration
                ))
            }
        }
        return transcriptSegments.sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return (lhs.speakerLabel ?? "") < (rhs.speakerLabel ?? "")
            }
            return lhs.startTime < rhs.startTime
        }
    }

    private func transcribe(
        range: RecordingAudioSegmentRangeRecord,
        segment: RecordingAudioSegmentRecord,
        audioURL: URL,
        session: RecordingSessionRecord,
        translationConfiguration: TranslationConfiguration
    ) async throws -> [TranscriptSegment] {
        guard let frameCount = range.frameCount else {
            throw BatchSpeechTranscriberError.invalidAudioRange
        }
        var segments = try await BatchSpeechTranscriberService.transcribe(
            BatchSpeechTranscriptionRequest(
                audioURL: audioURL,
                startFrame: range.startFrame,
                frameCount: frameCount,
                locale: Locale(identifier: range.localeIdentifier),
                source: segment.source,
                recordingSessionId: session.id,
                recordingStartTime: session.startedAt,
                sessionOffsetSeconds: range.sessionOffsetSeconds
            )
        )
        guard translationConfiguration.isEnabled,
              TranscriptTranslationLanguage.shouldTranslate(
                  transcriptionLocaleIdentifier: range.localeIdentifier,
                  targetLanguageIdentifier: translationConfiguration.targetLanguage
              ) else { return segments }

        for index in segments.indices {
            segments[index].translatedText = await translationService.translate(
                segments[index].text,
                from: range.localeIdentifier,
                to: translationConfiguration.targetLanguage
            )
        }
        return segments
    }

    private func fetchJob(sessionId: UUID) throws -> Job {
        try dbQueue.read { db in
            guard let session = try RecordingSessionRecord.fetchOne(db, key: sessionId),
                  let meeting = try MeetingRecord.fetchOne(db, key: session.meetingId),
                  let vault = try VaultRecord.fetchOne(db, key: meeting.vaultId) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let projectName: String = if let projectId = meeting.projectId,
                                         let project = try ProjectRecord.fetchOne(db, key: projectId) {
                project.name
            } else {
                ""
            }
            let segmentCount = try RecordingAudioSegmentRecord
                .filter(Column("recordingSessionId") == sessionId)
                .fetchCount(db)
            guard segmentCount > 0 else {
                throw CocoaError(.fileNoSuchFile)
            }
            return Job(
                session: session,
                meeting: meeting,
                vault: vault,
                projectName: projectName
            )
        }
    }

    private func exportTranscript(for job: Job) throws {
        let detail = try dbQueue.read { db in
            let segments = try TranscriptSegmentRecord
                .filter(Column("meetingId") == job.meeting.id)
                .order(Column("startTime").asc)
                .fetchAll(db)
            let sessions = try RecordingSessionRecord
                .filter(Column("meetingId") == job.meeting.id)
                .order(Column("offsetSeconds").asc, Column("startedAt").asc)
                .fetchAll(db)
            return (segments, sessions)
        }
        _ = try TranscriptExportService.exportTranscript(
            vaultURL: job.vault.url,
            meetingId: job.meeting.id,
            projectName: job.projectName,
            createdAt: job.meeting.createdAt,
            segments: detail.0.map(TranscriptSegment.init(from:)),
            recordingSessions: detail.1.map(RecordingSessionTimeline.init)
        )
    }

    private func meetingId(for sessionId: UUID) throws -> UUID {
        try dbQueue.read { db in
            guard let meetingId = try UUID.fetchOne(
                db,
                sql: "SELECT meetingId FROM recording_sessions WHERE id = ?",
                arguments: [sessionId]
            ) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return meetingId
        }
    }

    private func recordFailure(sessionId: UUID, error: Error) async {
        let message = error.localizedDescription
        let kind: BatchFailureKind = switch error as? RecordingAudioStoreError {
        case .ambiguousFiles, .integrityMismatch, .invalidPath, .invalidState, .missingFile:
            .recordingAudioPermanent
        default:
            .transcription
        }
        await persistFailure(sessionId: sessionId, message: message, kind: kind)
        ErrorReportingService.capture(error, context: ["source": "batchTranscription"])
    }

    private func persistFailure(sessionId: UUID, message: String, kind: BatchFailureKind? = nil) async {
        let didPersist = await (try? dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE recording_sessions
                SET batchLastError = ?, batchFailureKind = ?, updatedAt = ?
                WHERE id = ? AND batchDiscardedAt IS NULL
                """,
                arguments: [message, kind, Date.now, sessionId]
            )
            return db.changesCount == 1
        }) ?? false
        if didPersist, let meetingId = try? meetingId(for: sessionId) {
            await notify(meetingId: meetingId, state: .failed(sessionId: sessionId, message: message))
        }
    }

    private func notify(meetingId: UUID, state: BatchTranscriptionState) async {
        await onStateChange(BatchTranscriptionUpdate(meetingId: meetingId, state: state))
    }
}
