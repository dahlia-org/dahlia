import Foundation
import GRDB
import os

/// 確定済み文字起こしを MainActor に依存せず、順序を保って SQLite へ保存する。
actor TranscriptPersistenceWriter {
    struct MetricsSnapshot: Equatable, Sendable {
        let pendingEventCount: Int
        let pendingTextByteCount: Int
        let oldestPendingEventAge: Duration?
        let highWaterEventCount: Int
        let highWaterTextByteCount: Int
        let failedWriteAttemptCount: Int
        let currentRetryBackoff: Duration?
        let isWriteInProgress: Bool
        let waitingFlushCount: Int
        let maximumWriteDuration: Duration
        let lastWriteDuration: Duration
    }

    private struct PendingEvent {
        let event: TranscriptionEvent
        let acceptedAt: ContinuousClock.Instant
        let textByteCount: Int
    }

    private let dbQueue: DatabaseQueue
    private let meetingId: UUID
    private let recordingSessionId: UUID
    private let persistencePolicy: TranscriptPersistencePolicy

    private var persistedSegmentIds: Set<UUID>
    private var persistedSegmentTranslations: [UUID: String] = [:]
    private var pendingTranslations: [UUID: String] = [:]
    private var pendingEvents: [PendingEvent] = []
    private var nextAutomaticRetry: ContinuousClock.Instant?
    private var automaticRetryTask: Task<Void, Never>?
    private var automaticRetryDelayMilliseconds = 250
    private let maximumAutomaticRetryDelayMilliseconds = 30000
    private var isFlushing = false
    private var flushWaiters: [CheckedContinuation<Result<Void, Error>, Never>] = []
    private var pendingTextByteCount = 0
    private var highWaterEventCount = 0
    private var highWaterTextByteCount = 0
    private var failedWriteAttemptCount = 0
    private var currentRetryBackoff: Duration?
    private var maximumWriteDuration: Duration = .zero
    private var lastWriteDuration: Duration = .zero
    private static let logger = Logger(subsystem: "com.dahlia", category: "TranscriptPersistence")

    init(
        dbQueue: DatabaseQueue,
        meetingId: UUID,
        recordingSessionId: UUID,
        persistencePolicy: TranscriptPersistencePolicy,
        existingSegmentIds: Set<UUID> = []
    ) {
        self.dbQueue = dbQueue
        self.meetingId = meetingId
        self.recordingSessionId = recordingSessionId
        self.persistencePolicy = persistencePolicy
        self.persistedSegmentIds = existingSegmentIds
    }

    func persist(_ event: TranscriptionEvent) async throws {
        try await persist([event])
    }

    /// 連続して到着したイベントを、単一の DB transaction で反映する。
    func persist(_ events: [TranscriptionEvent]) async throws {
        guard persistencePolicy.persistsStreamingSegments, !events.isEmpty else { return }
        let acceptedAt = ContinuousClock.now
        let newEvents = events.map {
            PendingEvent(
                event: $0,
                acceptedAt: acceptedAt,
                textByteCount: $0.durableTextByteCount
            )
        }
        pendingEvents.append(contentsOf: newEvents)
        pendingTextByteCount += newEvents.reduce(0) { $0 + $1.textByteCount }
        highWaterEventCount = max(highWaterEventCount, pendingEvents.count)
        highWaterTextByteCount = max(highWaterTextByteCount, pendingTextByteCount)
        if let nextAutomaticRetry, ContinuousClock.now < nextAutomaticRetry {
            return
        }
        try await flushPending()
    }

    func metricsSnapshot() -> MetricsSnapshot {
        MetricsSnapshot(
            pendingEventCount: pendingEvents.count,
            pendingTextByteCount: pendingTextByteCount,
            oldestPendingEventAge: pendingEvents.first.map { $0.acceptedAt.duration(to: .now) },
            highWaterEventCount: highWaterEventCount,
            highWaterTextByteCount: highWaterTextByteCount,
            failedWriteAttemptCount: failedWriteAttemptCount,
            currentRetryBackoff: currentRetryBackoff,
            isWriteInProgress: isFlushing,
            waitingFlushCount: flushWaiters.count,
            maximumWriteDuration: maximumWriteDuration,
            lastWriteDuration: lastWriteDuration
        )
    }

    /// 失敗済みイベントも含め、actor が保持する durable event を transaction で再試行する。
    func flushPending() async throws {
        guard persistencePolicy.persistsStreamingSegments, !pendingEvents.isEmpty else { return }
        if isFlushing {
            let result = await withCheckedContinuation { continuation in
                flushWaiters.append(continuation)
            }
            try result.get()
            return
        }

        isFlushing = true
        let result: Result<Void, Error>
        do {
            while !pendingEvents.isEmpty {
                try await flushNextBatch()
            }
            result = .success(())
        } catch {
            result = .failure(error)
        }
        isFlushing = false
        let waiters = flushWaiters
        flushWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume(returning: result) }
        try result.get()
    }

    private func flushNextBatch() async throws {
        try Task.checkCancellation()

        let pendingEntries = pendingEvents
        let events = pendingEntries.map(\.event)
        let batchTextByteCount = pendingEntries.reduce(0) { $0 + $1.textByteCount }
        var plan = TranscriptPersistencePlan(
            persistedSegmentIds: persistedSegmentIds,
            persistedSegmentTranslations: persistedSegmentTranslations,
            pendingTranslations: pendingTranslations
        )
        for event in events {
            plan.consume(event, meetingId: meetingId, recordingSessionId: recordingSessionId)
        }
        let records = plan.records
        let translationUpdates = plan.translationUpdates

        let writeStartedAt = ContinuousClock.now
        do {
            try await dbQueue.write { db in
                for record in records {
                    try record.insert(db)
                }
                for (id, translatedText) in translationUpdates {
                    try TranscriptSegmentRecord.updateTranslatedText(
                        translatedText,
                        id: id,
                        in: db
                    )
                }
            }
        } catch {
            recordWriteDuration(since: writeStartedAt)
            failedWriteAttemptCount += 1
            scheduleAutomaticRetry()
            logWriteMetrics(
                eventCount: events.count,
                textByteCount: batchTextByteCount,
                succeeded: false
            )
            throw error
        }
        recordWriteDuration(since: writeStartedAt)

        persistedSegmentIds = plan.persistedSegmentIds
        persistedSegmentTranslations = plan.persistedSegmentTranslations
        pendingTranslations = plan.pendingTranslations
        pendingEvents.removeFirst(events.count)
        pendingTextByteCount -= batchTextByteCount
        nextAutomaticRetry = nil
        currentRetryBackoff = nil
        automaticRetryDelayMilliseconds = 250
        automaticRetryTask?.cancel()
        automaticRetryTask = nil
        logWriteMetrics(
            eventCount: events.count,
            textByteCount: batchTextByteCount,
            succeeded: true
        )
    }

    func resetTracking() async throws {
        try await flushPending()
        persistedSegmentIds.removeAll()
        persistedSegmentTranslations.removeAll()
        pendingTranslations.removeAll()
    }

    private func scheduleAutomaticRetry() {
        let delay = Duration.milliseconds(automaticRetryDelayMilliseconds)
        nextAutomaticRetry = ContinuousClock.now + delay
        currentRetryBackoff = delay
        automaticRetryDelayMilliseconds = min(
            automaticRetryDelayMilliseconds * 2,
            maximumAutomaticRetryDelayMilliseconds
        )
        automaticRetryTask?.cancel()
        automaticRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.runAutomaticRetry()
        }
    }

    private func runAutomaticRetry() async {
        automaticRetryTask = nil
        do {
            try await flushPending()
        } catch {
            // flushPending() schedules the next backoff before propagating the failure.
        }
    }

    private func recordWriteDuration(since startedAt: ContinuousClock.Instant) {
        lastWriteDuration = startedAt.duration(to: .now)
        maximumWriteDuration = max(maximumWriteDuration, lastWriteDuration)
    }

    private func logWriteMetrics(eventCount: Int, textByteCount: Int, succeeded: Bool) {
        let oldestPendingAge = pendingEvents.first.map { $0.acceptedAt.duration(to: .now) }
        Self.logger.debug(
            """
            SQLite transcript write succeeded=\(succeeded, privacy: .public) \
            events=\(eventCount, privacy: .public) textBytes=\(textByteCount, privacy: .public) \
            pendingEvents=\(self.pendingEvents.count, privacy: .public) \
            pendingTextBytes=\(self.pendingTextByteCount, privacy: .public) \
            oldestPendingMs=\((oldestPendingAge ?? .zero).milliseconds, privacy: .public) \
            highWaterEvents=\(self.highWaterEventCount, privacy: .public) \
            highWaterTextBytes=\(self.highWaterTextByteCount, privacy: .public) \
            durationMs=\(self.lastWriteDuration.milliseconds, privacy: .public) \
            maximumDurationMs=\(self.maximumWriteDuration.milliseconds, privacy: .public) \
            failedAttempts=\(self.failedWriteAttemptCount, privacy: .public) \
            retryBackoffMs=\((self.currentRetryBackoff ?? .zero).milliseconds, privacy: .public) \
            writeInProgress=\(self.isFlushing, privacy: .public) \
            waitingFlushes=\(self.flushWaiters.count, privacy: .public)
            """
        )
    }

}

private struct TranscriptPersistencePlan {
    var persistedSegmentIds: Set<UUID>
    var persistedSegmentTranslations: [UUID: String]
    var pendingTranslations: [UUID: String]
    private var insertOrder: [UUID] = []
    private var inserts: [UUID: TranscriptSegmentRecord] = [:]
    private(set) var translationUpdates: [UUID: String] = [:]

    init(
        persistedSegmentIds: Set<UUID>,
        persistedSegmentTranslations: [UUID: String],
        pendingTranslations: [UUID: String]
    ) {
        self.persistedSegmentIds = persistedSegmentIds
        self.persistedSegmentTranslations = persistedSegmentTranslations
        self.pendingTranslations = pendingTranslations
    }

    var records: [TranscriptSegmentRecord] {
        insertOrder.compactMap { inserts[$0] }
    }

    mutating func consume(
        _ event: TranscriptionEvent,
        meetingId: UUID,
        recordingSessionId: UUID
    ) {
        switch event {
        case let .finalized(segment) where segment.isConfirmed:
            consumeFinalized(
                segment,
                meetingId: meetingId,
                recordingSessionId: recordingSessionId
            )
        case let .translation(_, segmentId, translatedText):
            consumeTranslation(translatedText, segmentId: segmentId)
        case .preview, .clearPreview, .previewTranslation, .failure, .finalized:
            break
        }
    }

    private mutating func consumeFinalized(
        _ segment: TranscriptSegment,
        meetingId: UUID,
        recordingSessionId: UUID
    ) {
        var record = TranscriptSegmentRecord(
            from: segment,
            meetingId: meetingId,
            defaultSessionId: recordingSessionId
        )
        if let pendingTranslation = pendingTranslations.removeValue(forKey: segment.id) {
            record.translatedText = pendingTranslation
        }

        guard persistedSegmentIds.insert(segment.id).inserted else {
            updateTranslationIfNeeded(record.translatedText, segmentId: segment.id)
            return
        }

        insertOrder.append(segment.id)
        inserts[segment.id] = record
        if let translatedText = record.translatedText {
            persistedSegmentTranslations[segment.id] = translatedText
        }
    }

    private mutating func consumeTranslation(_ translatedText: String?, segmentId: UUID) {
        // 翻訳失敗を表す nil で、すでに保存済みの翻訳を巻き戻さない。
        guard let translatedText else { return }
        guard persistedSegmentIds.contains(segmentId) else {
            pendingTranslations[segmentId] = translatedText
            return
        }

        if var pendingInsert = inserts[segmentId] {
            pendingInsert.translatedText = translatedText
            inserts[segmentId] = pendingInsert
        } else if persistedSegmentTranslations[segmentId] != translatedText {
            translationUpdates[segmentId] = translatedText
        }
        persistedSegmentTranslations[segmentId] = translatedText
    }

    private mutating func updateTranslationIfNeeded(_ translatedText: String?, segmentId: UUID) {
        guard let translatedText,
              persistedSegmentTranslations[segmentId] != translatedText else { return }
        translationUpdates[segmentId] = translatedText
        persistedSegmentTranslations[segmentId] = translatedText
    }
}
