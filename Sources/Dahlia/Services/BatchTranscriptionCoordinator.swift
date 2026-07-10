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
        let files: [RecordingAudioFileRecord]
        let rangesByFileId: [UUID: [RecordingAudioRangeRecord]]
    }

    private struct TranslationConfiguration {
        let isEnabled: Bool
        let targetLanguage: String
    }

    private let dbQueue: DatabaseQueue
    private let managedRootURL: URL
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
        self.managedRootURL = managedRootURL
        self.onStateChange = onStateChange
    }

    func recoverAndEnqueue() async {
        BatchTranscriptionRecoveryService.reconcileCompletedAudioFiles(
            dbQueue: dbQueue,
            managedRootURL: managedRootURL
        )
        let recoveryFailures = await BatchInterruptedRecordingRecoveryService.recover(
            dbQueue: dbQueue,
            managedRootURL: managedRootURL
        )
        for failure in recoveryFailures {
            await persistFailure(sessionId: failure.sessionId, message: failure.message)
        }
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
            enqueue(sessionId: sessionId)
        }
    }

    static func shouldAutomaticallyRetry(_ session: RecordingSessionRecord) -> Bool {
        guard session.transcriptionMode == .batch,
              session.batchCompletedAt == nil,
              session.batchDiscardedAt == nil else { return false }
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
        let meetingId = try await BatchTranscriptionConfirmationService.confirm(
            sessionId: sessionId,
            localeIdentifier: localeIdentifier,
            retainAudioAfterBatch: retainAudioAfterBatch,
            dbQueue: dbQueue
        )
        await notify(meetingId: meetingId, state: .queued(sessionId: sessionId))
        enqueue(sessionId: sessionId)
    }

    func enqueue(sessionId: UUID) {
        guard runningSessionId != sessionId, !pendingSessionIds.contains(sessionId) else { return }
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
        await persistFailure(sessionId: sessionId, message: message)
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
                let meetingId = try meetingId(for: sessionId)
                await notify(meetingId: meetingId, state: .running(sessionId: sessionId))
                try await process(sessionId: sessionId)
                await notify(meetingId: meetingId, state: .completed(sessionId: sessionId))
            } catch {
                await recordFailure(sessionId: sessionId, error: error)
            }
            runningSessionId = nil
        }
        processorTask = nil
    }

    private func process(sessionId: UUID) async throws {
        try await markAttemptStarted(sessionId: sessionId)
        // 手動再試行でもpartial CAFを確定し、実フレーム数へメタデータを揃えてから解析する。
        try BatchTranscriptionRecoveryService.recoverAudioMetadataIfNeeded(
            sessionId: sessionId,
            dbQueue: dbQueue,
            managedRootURL: managedRootURL
        )
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

        performPostProcessing(for: job)
    }

    private func performPostProcessing(for job: Job) {
        do {
            try exportTranscript(for: job)
        } catch {
            ErrorReportingService.capture(error, context: ["source": "batchTranscriptExport"])
        }
        guard job.session.retainAudioAfterBatch else {
            BatchAudioStorage.removeFiles(
                job.files,
                managedRootURL: managedRootURL,
                vaultURL: job.vault.url
            )
            return
        }
        do {
            try BatchAudioRetentionService.retainCompletedAudio(
                sessionId: job.session.id,
                dbQueue: dbQueue,
                managedRootURL: managedRootURL
            )
        } catch {
            ErrorReportingService.capture(error, context: ["source": "batchAudioRetention"])
        }
    }

    private func markAttemptStarted(sessionId: UUID) async throws {
        let attemptDate = Date.now
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE recording_sessions
                SET batchLastAttemptAt = ?, batchAttemptCount = batchAttemptCount + 1,
                    batchLastError = NULL, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [attemptDate, attemptDate, sessionId]
            )
        }
    }

    private func transcribe(job: Job) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        let translationConfiguration = await MainActor.run {
            TranslationConfiguration(
                isEnabled: AppSettings.shared.transcriptTranslationEnabled,
                targetLanguage: AppSettings.shared.transcriptTranslationTargetLanguage
            )
        }

        for file in job.files {
            guard let audioURL = BatchAudioStorage.existingURL(
                for: file,
                managedRootURL: managedRootURL,
                vaultURL: job.vault.url
            ) else {
                throw CocoaError(.fileNoSuchFile)
            }
            for range in job.rangesByFileId[file.id] ?? [] {
                try await segments.append(contentsOf: transcribe(
                    range: range,
                    file: file,
                    audioURL: audioURL,
                    session: job.session,
                    translationConfiguration: translationConfiguration
                ))
            }
        }
        return segments.sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return (lhs.speakerLabel ?? "") < (rhs.speakerLabel ?? "")
            }
            return lhs.startTime < rhs.startTime
        }
    }

    private func transcribe(
        range: RecordingAudioRangeRecord,
        file: RecordingAudioFileRecord,
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
                source: file.source,
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
            let files = try RecordingAudioFileRecord
                .filter(Column("recordingSessionId") == sessionId)
                .order(Column("source").asc)
                .fetchAll(db)
            guard !files.isEmpty else {
                throw CocoaError(.fileNoSuchFile)
            }
            var rangesByFileId: [UUID: [RecordingAudioRangeRecord]] = [:]
            for file in files {
                rangesByFileId[file.id] = try RecordingAudioRangeRecord
                    .filter(Column("audioFileId") == file.id)
                    .order(Column("startFrame").asc)
                    .fetchAll(db)
            }
            return Job(
                session: session,
                meeting: meeting,
                vault: vault,
                projectName: projectName,
                files: files,
                rangesByFileId: rangesByFileId
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
        await persistFailure(sessionId: sessionId, message: message)
        ErrorReportingService.capture(error, context: ["source": "batchTranscription"])
    }

    private func persistFailure(sessionId: UUID, message: String) async {
        try? await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE recording_sessions SET batchLastError = ?, updatedAt = ? WHERE id = ?",
                arguments: [message, Date.now, sessionId]
            )
        }
        if let meetingId = try? meetingId(for: sessionId) {
            await notify(meetingId: meetingId, state: .failed(sessionId: sessionId, message: message))
        }
    }

    private func notify(meetingId: UUID, state: BatchTranscriptionState) async {
        await onStateChange(BatchTranscriptionUpdate(meetingId: meetingId, state: state))
    }
}
