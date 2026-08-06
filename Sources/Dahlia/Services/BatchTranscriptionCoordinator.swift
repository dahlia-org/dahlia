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

    private static let signposter = OSSignposter(subsystem: "com.dahlia", category: "BatchTranscription")

    struct Job {
        let session: RecordingSessionRecord
        let meeting: MeetingRecord
        let vault: VaultRecord
        let projectName: String
    }

    private struct TranslationConfiguration: Sendable {
        let isEnabled: Bool
        let targetLanguage: String
    }

    private let dbQueue: DatabaseQueue
    private let recordingAudioStore: RecordingAudioStore?
    private let translationService = TranscriptTranslationService()
    private let languageDetector: any BatchLanguageDetecting
    private let speechRecognizer: any BatchSpeechRecognizing
    private let audioFeatureAnalyzer: any BatchTranscriptAudioFeatureAnalyzing
    private let supportedLocalesProvider: @Sendable () async -> [Locale]
    let languageFallbackReporter: LanguageFallbackReporter
    let onStateChange: StateHandler
    private var pendingSessionIds: [UUID] = []
    private var runningSessionId: UUID?
    private var runningProgress: BatchTranscriptionProgress?
    private var processorTask: Task<Void, Never>?
    private var pendingProgressUpdate: BatchTranscriptionUpdate?
    private var progressNotificationTask: Task<Void, Never>?
    private var isShuttingDown = false
    private var shutdownInterruptionSessionIds: Set<UUID> = []
    private var activeConfirmationCount = 0
    private var confirmationDrainWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        dbQueue: DatabaseQueue,
        managedRootURL: URL = BatchAudioStorage.managedRootURL,
        languageDetector: any BatchLanguageDetecting = WhisperKitBatchLanguageDetector(),
        speechRecognizer: any BatchSpeechRecognizing = AppleBatchSpeechRecognizer(),
        audioFeatureAnalyzer: any BatchTranscriptAudioFeatureAnalyzing = BatchTranscriptAudioFeatureAnalyzer(),
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
        self.audioFeatureAnalyzer = audioFeatureAnalyzer
        self.supportedLocalesProvider = supportedLocalesProvider
        self.languageFallbackReporter = languageFallbackReporter ?? { fallbacks, candidates in
            ErrorReportingService.capture(
                BatchLanguageFallbacksObserved(count: fallbacks.count),
                context: Self.languageFallbackReportContext(fallbacks, candidates: candidates)
            )
        }
        self.onStateChange = onStateChange
    }

    func recoverAndEnqueue() async throws {
        _ = await recordingAudioStore?.reconcileStartup()
        await recoverCompletedAudioPurges()
        try await markPreviouslyQueuedSessionsInterrupted()
    }

    func enqueue(sessionId: UUID) async {
        guard !isShuttingDown else {
            shutdownInterruptionSessionIds.insert(sessionId)
            return
        }
        guard runningSessionId != sessionId, !pendingSessionIds.contains(sessionId) else { return }
        do {
            guard try await claimForQueue(sessionId: sessionId) else { return }
        } catch {
            ErrorReportingService.capture(error, context: ["source": "batchTranscriptionQueue"])
            return
        }
        guard !isShuttingDown else {
            shutdownInterruptionSessionIds.insert(sessionId)
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
        await persistFailureIfPossible(
            sessionId: sessionId,
            message: message,
            kind: .recordingStorage
        )
        ErrorReportingService.capture(
            BatchRecordingFailure(message: message),
            context: ["source": "batchRecording"]
        )
    }

    private func processQueue() async {
        repeat {
            while !pendingSessionIds.isEmpty, !Task.isCancelled {
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
                    // Shutdown and explicit discard persist their own terminal state.
                } catch {
                    await recordFailure(sessionId: sessionId, error: error)
                }
                runningSessionId = nil
                runningProgress = nil
            }
            await languageDetector.unload()
            await speechRecognizer.unload()
            if Task.isCancelled { break }
        } while !pendingSessionIds.isEmpty
        processorTask = nil
    }

    func shutdown() async throws {
        isShuttingDown = true
        await waitForConfirmationDrain()
        shutdownInterruptionSessionIds.formUnion(pendingSessionIds)
        if let runningSessionId {
            shutdownInterruptionSessionIds.insert(runningSessionId)
        }
        pendingSessionIds.removeAll()
        let task = processorTask
        task?.cancel()
        await task?.value

        var firstError: (any Error)?
        for sessionId in Array(shutdownInterruptionSessionIds) {
            do {
                try await persistInterrupted(sessionId: sessionId)
                shutdownInterruptionSessionIds.remove(sessionId)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            isShuttingDown = false
            throw firstError
        }
    }

    #if DEBUG
        func isWaitingForConfirmationDrainForTesting() -> Bool {
            isShuttingDown && activeConfirmationCount > 0
        }
    #endif

    private func markPreviouslyQueuedSessionsInterrupted() async throws {
        let sessionIds = try await dbQueue.write { db -> [UUID] in
            let ids = try UUID.fetchAll(
                db,
                sql: """
                SELECT id FROM recording_sessions
                WHERE transcriptionMode = ?
                  AND batchDiscardedAt IS NULL
                  AND batchLastAttemptAt IS NOT NULL
                  AND (batchCompletedAt IS NULL OR batchLastAttemptAt > batchCompletedAt)
                  AND batchLastError IS NULL
                """,
                arguments: [TranscriptionMode.batch.rawValue]
            )
            guard !ids.isEmpty else { return ids }
            var updateArguments: StatementArguments = [
                L10n.batchTranscriptionInterrupted,
                BatchFailureKind.transcriptionInterrupted.rawValue,
                Date.now,
            ]
            updateArguments += StatementArguments(ids)
            try db.execute(
                sql: """
                UPDATE recording_sessions
                SET batchLastError = ?, batchFailureKind = ?, updatedAt = ?
                WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ", ")))
                """,
                arguments: updateArguments
            )
            return ids
        }
        for sessionId in sessionIds {
            guard let context = try? failureNotificationContext(for: sessionId) else { continue }
            await notify(
                meetingId: context.meetingId,
                state: .interrupted(sessionId: sessionId, isRetranscription: context.isRetranscription)
            )
        }
    }

    private func persistInterrupted(sessionId: UUID) async throws {
        try await persistFailure(
            sessionId: sessionId,
            message: L10n.batchTranscriptionInterrupted,
            kind: .transcriptionInterrupted
        )
    }

    private func waitForConfirmationDrain() async {
        guard activeConfirmationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            confirmationDrainWaiters.append(continuation)
        }
    }

    private func beginConfirmation() throws {
        guard !isShuttingDown else { throw CancellationError() }
        activeConfirmationCount += 1
    }

    private func finishConfirmation() {
        activeConfirmationCount -= 1
        guard activeConfirmationCount == 0 else { return }
        let waiters = confirmationDrainWaiters
        confirmationDrainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
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
        MeetingConversationMetricsRefreshService.schedule(
            meetingId: job.meeting.id,
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
        let workItems = try transcriptionWorkItems(
            verifiedSegments: verifiedSegments,
            job: job,
            supportedLocales: supportedLocales,
            automaticLanguageCandidateLocales: automaticLanguageCandidateLocales,
            automaticLanguageCandidates: automaticLanguageCandidates
        )
        await notifyProgress(
            meetingId: job.meeting.id,
            sessionId: job.session.id,
            completedFileCount: 0,
            totalFileCount: totalFileCount
        )
        let recognitionState = Self.signposter.beginInterval("Recognize audio runs")
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
            Self.signposter.endInterval("Recognize audio runs", recognitionState)
        } catch {
            Self.signposter.endInterval("Recognize audio runs", recognitionState)
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
        fallbackCollector: BatchLanguageFallbackCollector,
        onFileConsumed: @escaping @Sendable (Int) async -> Void
    ) async throws -> TranscriptionWorkResult {
        let result: BatchSpeechTranscriptionResult
        switch workItem.request {
        case let .automatic(request):
            result = try await BatchSpeechTranscriberService.transcribe(
                request,
                languageDetector: languageDetector,
                speechRecognizer: speechRecognizer,
                audioFeatureAnalyzer: audioFeatureAnalyzer,
                onLanguageFallback: { fallback in
                    await fallbackCollector.record(fallback)
                }
            )
            for fileIndex in workItem.fileIndices {
                await onFileConsumed(fileIndex)
            }
        case let .manual(run):
            result = try await BatchManualSpeechTranscriberService.transcribe(
                run,
                speechRecognizer: speechRecognizer,
                audioFeatureAnalyzer: audioFeatureAnalyzer,
                onFileConsumed: onFileConsumed
            )
        case let .noAudio(localeIdentifier):
            result = BatchSpeechTranscriptionResult(
                segments: [],
                localeIdentifier: localeIdentifier,
                languageFallback: nil
            )
            for fileIndex in workItem.fileIndices {
                await onFileConsumed(fileIndex)
            }
        }
        return TranscriptionWorkResult(
            index: workItem.index,
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
                                         let project = try ProjectRecord.fetchResolved(id: projectId, in: db) {
                project.path
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
        let kind: BatchFailureKind = if case .analysisStalled = error as? BatchSpeechTranscriberError {
            .transcriptionStalled
        } else {
            switch error as? RecordingAudioStoreError {
            case .ambiguousFiles, .integrityMismatch, .invalidPath, .invalidState, .missingFile:
                .recordingAudioPermanent
            default:
                .transcription
            }
        }
        await persistFailureIfPossible(sessionId: sessionId, message: message, kind: kind)
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

    private func persistFailure(sessionId: UUID, message: String, kind: BatchFailureKind? = nil) async throws {
        let didPersist = try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE recording_sessions
                SET batchLastError = ?, batchFailureKind = ?, updatedAt = ?
                WHERE id = ?
                  AND batchDiscardedAt IS NULL
                  AND (batchCompletedAt IS NULL OR batchLastAttemptAt > batchCompletedAt)
                """,
                arguments: [message, kind, Date.now, sessionId]
            )
            return db.changesCount == 1
        }
        if didPersist, let result = try? failureNotificationContext(for: sessionId) {
            let state: BatchTranscriptionState = if kind == .transcriptionInterrupted {
                .interrupted(sessionId: sessionId, isRetranscription: result.isRetranscription)
            } else if result.isRetranscription {
                .retranscriptionFailed(sessionId: sessionId, message: message)
            } else {
                .failed(sessionId: sessionId, message: message)
            }
            await notify(meetingId: result.meetingId, state: state)
        }
    }

    private func persistFailureIfPossible(
        sessionId: UUID,
        message: String,
        kind: BatchFailureKind? = nil
    ) async {
        do {
            try await persistFailure(sessionId: sessionId, message: message, kind: kind)
        } catch {
            ErrorReportingService.capture(
                error,
                context: ["source": "batchTranscriptionFailurePersistence"]
            )
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
            let progressTracker = BatchTranscriptionFileProgressTracker(workItems: workItems)
            let reportFileConsumed: @Sendable (Int, Int) async -> Void = { [weak self] workItemIndex, fileIndex in
                guard let completedFileCount = await progressTracker.consume(
                    workItemIndex: workItemIndex,
                    fileIndex: fileIndex
                ) else { return }
                await self?.enqueueProgressNotification(
                    meetingId: meetingId,
                    sessionId: sessionId,
                    completedFileCount: completedFileCount,
                    totalFileCount: totalFileCount
                )
            }
            let initialCount = min(BatchTranscriptionConcurrency.appleSpeechMaximum, workItems.count)
            for workItem in workItems.prefix(initialCount) {
                group.addTask { [self] in
                    try await transcribe(
                        workItem: workItem,
                        fallbackCollector: fallbackCollector,
                        onFileConsumed: { fileIndex in
                            await reportFileConsumed(workItem.index, fileIndex)
                        }
                    )
                }
            }

            var nextIndex = initialCount
            var results: [TranscriptionWorkResult] = []
            do {
                while let result = try await group.next() {
                    results.append(result)
                    if nextIndex < workItems.count {
                        let workItem = workItems[nextIndex]
                        nextIndex += 1
                        group.addTask { [self] in
                            try await transcribe(
                                workItem: workItem,
                                fallbackCollector: fallbackCollector,
                                onFileConsumed: { fileIndex in
                                    await reportFileConsumed(workItem.index, fileIndex)
                                }
                            )
                        }
                    }
                }
                await finishProgressNotifications()
                return results
            } catch {
                group.cancelAll()
                await finishProgressNotifications()
                throw error
            }
        }
    }

    private func enqueueProgressNotification(
        meetingId: UUID,
        sessionId: UUID,
        completedFileCount: Int,
        totalFileCount: Int
    ) {
        pendingProgressUpdate = recordProgress(
            meetingId: meetingId,
            sessionId: sessionId,
            completedFileCount: completedFileCount,
            totalFileCount: totalFileCount
        )
        guard progressNotificationTask == nil else { return }
        progressNotificationTask = Task { [weak self] in
            await self?.deliverPendingProgressUpdates()
        }
    }

    private func deliverPendingProgressUpdates() async {
        while let update = pendingProgressUpdate {
            pendingProgressUpdate = nil
            await onStateChange(update)
        }
        progressNotificationTask = nil
    }

    private func finishProgressNotifications() async {
        await progressNotificationTask?.value
    }

    private func notifyProgress(
        meetingId: UUID,
        sessionId: UUID,
        completedFileCount: Int,
        totalFileCount: Int
    ) async {
        let update = recordProgress(
            meetingId: meetingId,
            sessionId: sessionId,
            completedFileCount: completedFileCount,
            totalFileCount: totalFileCount
        )
        await onStateChange(update)
    }

    private func recordProgress(
        meetingId: UUID,
        sessionId: UUID,
        completedFileCount: Int,
        totalFileCount: Int
    ) -> BatchTranscriptionUpdate {
        let progress = BatchTranscriptionProgress(
            completedFileCount: completedFileCount,
            totalFileCount: totalFileCount
        )
        runningProgress = progress
        return BatchTranscriptionUpdate(
            meetingId: meetingId,
            state: .running(sessionId: sessionId, progress: progress)
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
                  AND (
                      sessions.batchLastAttemptAt IS NULL
                      OR sessions.batchLastAttemptAt <= sessions.batchCompletedAt
                  )
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
        retainAudioAfterBatch: Bool,
        onConfirmed: @Sendable (BatchTranscriptionConfirmationService.Result) async -> Void
    ) async throws {
        try beginConfirmation()
        defer { finishConfirmation() }
        let result = try await BatchTranscriptionConfirmationService.confirm(
            sessionId: sessionId,
            languageSelection: languageSelection,
            automaticLanguageCandidates: automaticLanguageCandidates,
            retainAudioAfterBatch: retainAudioAfterBatch,
            dbQueue: dbQueue
        )
        await onConfirmed(result)
        for confirmedSessionId in result.sessionIds {
            await notify(meetingId: result.meetingId, state: .queued(sessionId: confirmedSessionId))
            await enqueue(sessionId: confirmedSessionId)
        }
    }

    func confirmRetranscriptionAndEnqueue(
        sessionIds: [UUID],
        languageSelection: BatchTranscriptionLanguageSelection,
        automaticLanguageCandidates: BatchLanguageDetectionCandidateSnapshot?,
        retainAudioAfterBatch: Bool,
        onConfirmed: @Sendable (BatchTranscriptionConfirmationService.Result) async -> Void
    ) async throws {
        try beginConfirmation()
        defer { finishConfirmation() }
        let result = try await BatchTranscriptionConfirmationService.confirmRetranscription(
            sessionIds: sessionIds,
            languageSelection: languageSelection,
            automaticLanguageCandidates: automaticLanguageCandidates,
            retainAudioAfterBatch: retainAudioAfterBatch,
            dbQueue: dbQueue
        )
        await onConfirmed(result)
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

private actor BatchTranscriptionFileProgressTracker {
    private struct Portion: Hashable {
        let workItemIndex: Int
        let fileIndex: Int
    }

    private var remainingWorkItemCountByFile: [Int: Int] = [:]
    private var consumedPortions: Set<Portion> = []
    private var completedFileCount = 0

    init(workItems: [BatchTranscriptionCoordinator.TranscriptionWorkItem]) {
        for workItem in workItems {
            for fileIndex in workItem.fileIndices {
                remainingWorkItemCountByFile[fileIndex, default: 0] += 1
            }
        }
    }

    func consume(workItemIndex: Int, fileIndex: Int) -> Int? {
        let portion = Portion(workItemIndex: workItemIndex, fileIndex: fileIndex)
        guard consumedPortions.insert(portion).inserted,
              let remainingCount = remainingWorkItemCountByFile[fileIndex] else {
            return nil
        }
        if remainingCount == 1 {
            remainingWorkItemCountByFile[fileIndex] = nil
            completedFileCount += 1
            return completedFileCount
        }
        remainingWorkItemCountByFile[fileIndex] = remainingCount - 1
        return nil
    }
}
