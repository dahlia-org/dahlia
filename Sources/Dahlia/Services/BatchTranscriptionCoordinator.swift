import Foundation
import GRDB
import os
import Speech

private struct BatchRecordingFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct BatchLanguageFallbacksObserved: LocalizedError {
    let count: Int

    var errorDescription: String? { "Batch language detection used fallback for \(count) CAF files" }
}

private actor BatchLanguageFallbackCollector {
    private var fallbacks: [BatchLanguageFallback] = []

    func record(_ fallback: BatchLanguageFallback) {
        fallbacks.append(fallback)
    }

    func snapshot() -> [BatchLanguageFallback] {
        fallbacks
    }
}

/// 未完了のバッチセッションを直列実行し、成功結果だけをDBへ反映する。
actor BatchTranscriptionCoordinator {
    typealias StateHandler = @Sendable (BatchTranscriptionUpdate) async -> Void
    typealias LanguageFallbackReporter = @Sendable (
        [BatchLanguageFallback],
        BatchLanguageDetectionCandidateSnapshot
    ) async -> Void

    static let maximumAutomaticAttemptCount = 3
    private static let signposter = OSSignposter(subsystem: "com.dahlia", category: "BatchTranscription")

    private struct Job {
        let session: RecordingSessionRecord
        let meeting: MeetingRecord
        let vault: VaultRecord
        let projectName: String
    }

    private struct TranslationConfiguration: Sendable {
        let isEnabled: Bool
        let targetLanguage: String
    }

    private struct TranscriptionWorkItem: Sendable {
        let index: Int
        let fileIndex: Int
        let request: BatchSpeechTranscriptionRequest
    }

    private struct TranscriptionWorkResult: Sendable {
        let index: Int
        let fileIndex: Int
        var segments: [TranscriptSegment]
        let localeIdentifier: String
    }

    private let dbQueue: DatabaseQueue
    private let recordingAudioStore: RecordingAudioStore?
    private let translationService = TranscriptTranslationService()
    private let languageDetector: any BatchLanguageDetecting
    private let speechRecognizer: any BatchSpeechRecognizing
    private let supportedLocalesProvider: @Sendable () async -> [Locale]
    let languageFallbackReporter: LanguageFallbackReporter
    let onStateChange: StateHandler
    private var pendingSessionIds: [UUID] = []
    private var runningSessionId: UUID?
    private var runningProgress: BatchTranscriptionProgress?
    private var processorTask: Task<Void, Never>?

    init(
        dbQueue: DatabaseQueue,
        managedRootURL: URL = BatchAudioStorage.managedRootURL,
        languageDetector: any BatchLanguageDetecting = WhisperKitBatchLanguageDetector(),
        speechRecognizer: any BatchSpeechRecognizing = AppleBatchSpeechRecognizer(),
        supportedLocalesProvider: @escaping @Sendable () async -> [Locale] = {
            await SpeechTranscriber.supportedLocales
        },
        languageFallbackReporter: LanguageFallbackReporter? = nil,
        onStateChange: @escaping StateHandler
    ) {
        self.dbQueue = dbQueue
        recordingAudioStore = try? RecordingAudioStore(
            dbQueue: dbQueue,
            managedRootURL: managedRootURL
        )
        self.languageDetector = SerializedBatchLanguageDetector(detector: languageDetector)
        self.speechRecognizer = AdaptiveBatchSpeechRecognizer(recognizer: speechRecognizer)
        self.supportedLocalesProvider = supportedLocalesProvider
        self.languageFallbackReporter = languageFallbackReporter ?? { fallbacks, candidates in
            ErrorReportingService.capture(
                BatchLanguageFallbacksObserved(count: fallbacks.count),
                context: Self.languageFallbackReportContext(fallbacks, candidates: candidates)
            )
        }
        self.onStateChange = onStateChange
    }

    func recoverAndEnqueue() async {
        _ = await recordingAudioStore?.reconcileStartup()
        await recoverCompletedAudioPurges()
        let sessionIds = await (try? dbQueue.read { db in
            try RecordingSessionRecord
                .filter(Column("transcriptionMode") == TranscriptionMode.batch.rawValue)
                .filter(sql: "batchCompletedAt IS NULL OR batchLastAttemptAt > batchCompletedAt")
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

    func runningState(sessionId: UUID) -> BatchTranscriptionState? {
        guard runningSessionId == sessionId else { return nil }
        return .running(sessionId: sessionId, progress: runningProgress)
    }

    func recordRecordingFailure(sessionId: UUID, message: String) async {
        await persistFailure(sessionId: sessionId, message: message, kind: .recordingStorage)
        ErrorReportingService.capture(
            BatchRecordingFailure(message: message),
            context: ["source": "batchRecording"]
        )
    }

    private func processQueue() async {
        repeat {
            while !pendingSessionIds.isEmpty {
                let sessionId = pendingSessionIds.removeFirst()
                runningSessionId = sessionId
                runningProgress = nil
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
                runningProgress = nil
            }
            await languageDetector.unload()
            await speechRecognizer.unload()
        } while !pendingSessionIds.isEmpty
        processorTask = nil
    }

    private func process(sessionId: UUID) async throws {
        let state = Self.signposter.beginInterval("Batch transcription")
        defer { Self.signposter.endInterval("Batch transcription", state) }
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
                SET batchLastAttemptAt = CASE
                        WHEN batchLastAttemptAt IS NULL OR ? > batchLastAttemptAt THEN ?
                        ELSE batchLastAttemptAt
                    END,
                    batchAttemptCount = batchAttemptCount + 1,
                    batchLastError = NULL, batchFailureKind = NULL, updatedAt = ?
                WHERE id = ?
                  AND (batchCompletedAt IS NULL OR batchLastAttemptAt > batchCompletedAt)
                  AND batchDiscardedAt IS NULL
                """,
                arguments: [attemptDate, attemptDate, attemptDate, sessionId]
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
                  AND (batchCompletedAt IS NULL OR batchLastAttemptAt > batchCompletedAt)
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
        let supportedLocales: [Locale] = if job.session.batchLanguageDetectionMode == .automatic {
            await supportedLocalesProvider()
        } else {
            []
        }
        let automaticLanguageCandidates: BatchLanguageDetectionCandidateSnapshot? = if job.session
            .batchLanguageDetectionMode == .automatic {
            try automaticLanguageCandidates(for: job.session)
        } else {
            nil
        }
        let automaticLanguageCandidateLocales = automaticLanguageCandidates.map {
            BatchLanguageDetectionCandidateResolver.candidates(snapshot: $0, supportedLocales: supportedLocales).locales
        }
        let totalFileCount = verifiedSegments.count
        var workItems: [TranscriptionWorkItem] = []
        for (fileIndex, verified) in verifiedSegments.enumerated() {
            let ranges = try BatchTranscriptionAudioRangePlanner.ranges(
                for: verified,
                mode: job.session.batchLanguageDetectionMode
            )
            for range in ranges {
                workItems.append(
                    TranscriptionWorkItem(
                        index: workItems.count,
                        fileIndex: fileIndex,
                        request: BatchSpeechTranscriptionRequest(
                            audioURL: verified.url,
                            startFrame: range.startFrame,
                            frameCount: range.frameCount,
                            recordedLocaleIdentifiers: range.recordedLocaleIdentifiers,
                            languageDetectionMode: job.session.batchLanguageDetectionMode,
                            supportedLocales: supportedLocales,
                            automaticLanguageCandidateLocales: automaticLanguageCandidateLocales,
                            allowedLanguageIdentifiers: automaticLanguageCandidates?.identifierSet,
                            source: verified.segment.source,
                            recordingSessionId: job.session.id,
                            recordingStartTime: job.session.startedAt,
                            sessionOffsetSeconds: range.sessionOffsetSeconds
                        )
                    )
                )
            }
        }
        await notifyProgress(
            meetingId: job.meeting.id,
            sessionId: job.session.id,
            completedFileCount: 0,
            totalFileCount: totalFileCount
        )
        let recognitionState = Self.signposter.beginInterval("Recognize CAF files")
        let fallbackCollector = BatchLanguageFallbackCollector()
        var workResults: [TranscriptionWorkResult]
        do {
            workResults = try await transcribeConcurrently(
                workItems: workItems,
                fallbackCollector: fallbackCollector,
                meetingId: job.meeting.id,
                sessionId: job.session.id,
                totalFileCount: totalFileCount
            )
            .sorted { $0.index < $1.index }
            Self.signposter.endInterval("Recognize CAF files", recognitionState)
        } catch {
            Self.signposter.endInterval("Recognize CAF files", recognitionState)
            await reportLanguageFallbacks(
                fallbackCollector.snapshot(),
                candidates: automaticLanguageCandidates
            )
            throw error
        }
        await reportLanguageFallbacks(
            fallbackCollector.snapshot(),
            candidates: automaticLanguageCandidates
        )
        if translationConfiguration.isEnabled {
            workResults = try await translate(
                workResults: workResults,
                configuration: translationConfiguration
            )
        }
        let transcriptSegments = workResults.flatMap(\.segments)
        return transcriptSegments.sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return (lhs.speakerLabel ?? "") < (rhs.speakerLabel ?? "")
            }
            return lhs.startTime < rhs.startTime
        }
    }

    private func automaticLanguageCandidates(
        for session: RecordingSessionRecord
    ) throws -> BatchLanguageDetectionCandidateSnapshot {
        guard let encoded = session.batchAutomaticLanguageCandidatesJSON,
              let candidates = try? BatchLanguageDetectionCandidateSnapshot.decode(encoded),
              !candidates.languageIdentifiers.isEmpty else {
            throw BatchSpeechTranscriberError.noAutomaticLanguageCandidates
        }
        return candidates
    }

    private func translate(
        workResults: [TranscriptionWorkResult],
        configuration: TranslationConfiguration
    ) async throws -> [TranscriptionWorkResult] {
        let translationState = Self.signposter.beginInterval("Translate transcript")
        defer { Self.signposter.endInterval("Translate transcript", translationState) }
        var workResults = workResults
        let requests = workResults.flatMap { result in
            guard TranscriptTranslationLanguage.shouldTranslate(
                transcriptionLocaleIdentifier: result.localeIdentifier,
                targetLanguageIdentifier: configuration.targetLanguage
            ) else { return [TranscriptTranslationService.BatchRequest]() }
            return result.segments.map {
                TranscriptTranslationService.BatchRequest(
                    id: $0.id,
                    text: $0.text,
                    sourceLocaleIdentifier: result.localeIdentifier
                )
            }
        }
        let translations = try await translationService.translateBatch(
            requests,
            to: configuration.targetLanguage
        )
        for resultIndex in workResults.indices {
            for segmentIndex in workResults[resultIndex].segments.indices {
                let segmentId = workResults[resultIndex].segments[segmentIndex].id
                workResults[resultIndex].segments[segmentIndex].translatedText = translations[segmentId]
            }
        }
        return workResults
    }

    private func transcribe(
        workItem: TranscriptionWorkItem,
        fallbackCollector: BatchLanguageFallbackCollector
    ) async throws -> TranscriptionWorkResult {
        let result = try await BatchSpeechTranscriberService.transcribe(
            workItem.request,
            languageDetector: languageDetector,
            speechRecognizer: speechRecognizer,
            onLanguageFallback: { fallback in
                await fallbackCollector.record(fallback)
            }
        )
        return TranscriptionWorkResult(
            index: workItem.index,
            fileIndex: workItem.fileIndex,
            segments: result.segments,
            localeIdentifier: result.localeIdentifier
        )
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
        var context = [
            "source": "batchTranscription",
            "failureKind": kind.rawValue,
        ]
        if let transcriptionError = error as? BatchSpeechTranscriberError {
            context["errorCode"] = transcriptionError.diagnosticCode
            if case let .unsupportedDetectedLanguage(languageIdentifier) = transcriptionError {
                context["detectedLanguage"] = languageIdentifier
            }
        }
        ErrorReportingService.capture(error, context: context)
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
        if didPersist, let result = try? failureNotificationContext(for: sessionId) {
            let state: BatchTranscriptionState = result.isRetranscription
                ? .retranscriptionFailed(sessionId: sessionId, message: message)
                : .failed(sessionId: sessionId, message: message)
            await notify(meetingId: result.meetingId, state: state)
        }
    }

}

extension BatchTranscriptionCoordinator {
    private func transcribeConcurrently(
        workItems: [TranscriptionWorkItem],
        fallbackCollector: BatchLanguageFallbackCollector,
        meetingId: UUID,
        sessionId: UUID,
        totalFileCount: Int
    ) async throws -> [TranscriptionWorkResult] {
        try await withThrowingTaskGroup(of: TranscriptionWorkResult.self) { group in
            let initialCount = min(BatchTranscriptionConcurrency.appleSpeechMaximum, workItems.count)
            for workItem in workItems.prefix(initialCount) {
                group.addTask { [self] in
                    try await transcribe(workItem: workItem, fallbackCollector: fallbackCollector)
                }
            }

            var nextIndex = initialCount
            var results: [TranscriptionWorkResult] = []
            var remainingWorkItemCountByFile = Dictionary(
                grouping: workItems,
                by: \.fileIndex
            ).mapValues(\.count)
            var completedFileCount = 0
            do {
                while let result = try await group.next() {
                    results.append(result)
                    let didCompleteFile: Bool
                    if remainingWorkItemCountByFile[result.fileIndex] == 1 {
                        remainingWorkItemCountByFile[result.fileIndex] = nil
                        completedFileCount += 1
                        didCompleteFile = true
                    } else if let remainingCount = remainingWorkItemCountByFile[result.fileIndex] {
                        remainingWorkItemCountByFile[result.fileIndex] = remainingCount - 1
                        didCompleteFile = false
                    } else {
                        didCompleteFile = false
                    }
                    if nextIndex < workItems.count {
                        let workItem = workItems[nextIndex]
                        nextIndex += 1
                        group.addTask { [self] in
                            try await transcribe(workItem: workItem, fallbackCollector: fallbackCollector)
                        }
                    }
                    if didCompleteFile {
                        await notifyProgress(
                            meetingId: meetingId,
                            sessionId: sessionId,
                            completedFileCount: completedFileCount,
                            totalFileCount: totalFileCount
                        )
                    }
                }
                return results
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func notifyProgress(
        meetingId: UUID,
        sessionId: UUID,
        completedFileCount: Int,
        totalFileCount: Int
    ) async {
        let progress = BatchTranscriptionProgress(
            completedFileCount: completedFileCount,
            totalFileCount: totalFileCount
        )
        runningProgress = progress
        await notify(
            meetingId: meetingId,
            state: .running(
                sessionId: sessionId,
                progress: progress
            )
        )
    }

    /// Resumes the delete-after-transcription policy if the app stopped after committing a result.
    private func recoverCompletedAudioPurges() async {
        guard let recordingAudioStore else { return }
        let sessionIds = await (try? dbQueue.read { db in
            try UUID.fetchAll(
                db,
                sql: """
                SELECT sessions.id
                FROM recording_sessions AS sessions
                WHERE sessions.transcriptionMode = ?
                  AND sessions.batchCompletedAt IS NOT NULL
                  AND sessions.batchDiscardedAt IS NULL
                  AND sessions.audioRetentionPolicy = ?
                  AND EXISTS (
                      SELECT 1 FROM recording_audio_segments AS segments
                      WHERE segments.recordingSessionId = sessions.id
                        AND segments.state != ?
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM recording_audio_segments AS segments
                      WHERE segments.recordingSessionId = sessions.id
                        AND segments.state = ?
                  )
                """,
                arguments: [
                    TranscriptionMode.batch.rawValue,
                    RecordingAudioRetentionPolicy.deleteAfterTranscription.rawValue,
                    RecordingAudioSegmentState.purged.rawValue,
                    RecordingAudioSegmentState.failed.rawValue,
                ]
            )
        }) ?? []
        for sessionId in sessionIds {
            do {
                try await recordingAudioStore.requestPurge(sessionId: sessionId)
            } catch {
                ErrorReportingService.capture(error, context: ["source": "batchAudioPurgeRecovery"])
            }
        }
    }

    func confirmAndEnqueue(
        sessionId: UUID,
        languageSelection: BatchTranscriptionLanguageSelection,
        automaticLanguageCandidates: BatchLanguageDetectionCandidateSnapshot?,
        retainAudioAfterBatch: Bool
    ) async throws {
        let result = try await BatchTranscriptionConfirmationService.confirm(
            sessionId: sessionId,
            languageSelection: languageSelection,
            automaticLanguageCandidates: automaticLanguageCandidates,
            retainAudioAfterBatch: retainAudioAfterBatch,
            dbQueue: dbQueue
        )
        for confirmedSessionId in result.sessionIds {
            await notify(meetingId: result.meetingId, state: .queued(sessionId: confirmedSessionId))
            await enqueue(sessionId: confirmedSessionId)
        }
    }

    func confirmRetranscriptionAndEnqueue(
        sessionIds: [UUID],
        languageSelection: BatchTranscriptionLanguageSelection,
        automaticLanguageCandidates: BatchLanguageDetectionCandidateSnapshot?,
        retainAudioAfterBatch: Bool
    ) async throws {
        let result = try await BatchTranscriptionConfirmationService.confirmRetranscription(
            sessionIds: sessionIds,
            languageSelection: languageSelection,
            automaticLanguageCandidates: automaticLanguageCandidates,
            retainAudioAfterBatch: retainAudioAfterBatch,
            dbQueue: dbQueue
        )
        for sessionId in result.sessionIds {
            await notify(meetingId: result.meetingId, state: .queued(sessionId: sessionId))
            await enqueue(sessionId: sessionId)
        }
    }

    private func failureNotificationContext(for sessionId: UUID) throws -> (meetingId: UUID, isRetranscription: Bool) {
        try dbQueue.read { db in
            guard let session = try RecordingSessionRecord.fetchOne(db, key: sessionId) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return (session.meetingId, session.isBatchRetranscriptionPending)
        }
    }
}
