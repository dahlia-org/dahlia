import Foundation
import GRDB

/// 確定済み文字起こしを MainActor に依存せず、順序を保って SQLite へ保存する。
actor TranscriptPersistenceWriter {
    private let dbQueue: DatabaseQueue
    private let meetingId: UUID
    private let recordingSessionId: UUID
    private let persistencePolicy: TranscriptPersistencePolicy

    private var persistedSegmentIds: Set<UUID>
    private var persistedSegmentTranslations: [UUID: String] = [:]
    private var pendingTranslations: [UUID: String] = [:]
    private var pendingEvents: [TranscriptionEvent] = []
    private var nextAutomaticRetry: ContinuousClock.Instant?
    private var automaticRetryTask: Task<Void, Never>?
    private var automaticRetryDelayMilliseconds = 250
    private let maximumAutomaticRetryDelayMilliseconds = 30000

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
        pendingEvents.append(contentsOf: events)
        if let nextAutomaticRetry, ContinuousClock.now < nextAutomaticRetry {
            return
        }
        try await flushPending()
    }

    /// 失敗済みイベントも含め、actor が保持する durable event を transaction で再試行する。
    func flushPending() async throws {
        guard persistencePolicy.persistsStreamingSegments, !pendingEvents.isEmpty else { return }
        try Task.checkCancellation()

        let events = pendingEvents
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
            scheduleAutomaticRetry()
            throw error
        }

        persistedSegmentIds = plan.persistedSegmentIds
        persistedSegmentTranslations = plan.persistedSegmentTranslations
        pendingTranslations = plan.pendingTranslations
        pendingEvents.removeFirst(events.count)
        nextAutomaticRetry = nil
        automaticRetryDelayMilliseconds = 250
        automaticRetryTask?.cancel()
        automaticRetryTask = nil
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
