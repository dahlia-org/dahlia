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
        try Task.checkCancellation()

        var nextSegmentIds = persistedSegmentIds
        var nextTranslations = persistedSegmentTranslations
        var nextPendingTranslations = pendingTranslations
        var insertOrder: [UUID] = []
        var inserts: [UUID: TranscriptSegmentRecord] = [:]
        var translationUpdates: [UUID: String] = [:]

        for event in events {
            switch event {
            case let .finalized(segment) where segment.isConfirmed:
                var record = TranscriptSegmentRecord(
                    from: segment,
                    meetingId: meetingId,
                    defaultSessionId: recordingSessionId
                )
                if let pendingTranslation = nextPendingTranslations.removeValue(forKey: segment.id) {
                    record.translatedText = pendingTranslation
                }

                if nextSegmentIds.insert(segment.id).inserted {
                    insertOrder.append(segment.id)
                    inserts[segment.id] = record
                    if let translatedText = record.translatedText {
                        nextTranslations[segment.id] = translatedText
                    }
                } else if let translatedText = record.translatedText,
                          nextTranslations[segment.id] != translatedText {
                    translationUpdates[segment.id] = translatedText
                    nextTranslations[segment.id] = translatedText
                }

            case let .translation(_, segmentID, translatedText):
                // 翻訳失敗を表す nil で、すでに保存済みの翻訳を巻き戻さない。
                guard let translatedText else { continue }
                if nextSegmentIds.contains(segmentID) {
                    if var pendingInsert = inserts[segmentID] {
                        pendingInsert.translatedText = translatedText
                        inserts[segmentID] = pendingInsert
                    } else if nextTranslations[segmentID] != translatedText {
                        translationUpdates[segmentID] = translatedText
                    }
                    nextTranslations[segmentID] = translatedText
                } else {
                    nextPendingTranslations[segmentID] = translatedText
                }

            case .preview, .clearPreview, .previewTranslation, .failure, .finalized:
                break
            }
        }

        let records = insertOrder.compactMap { inserts[$0] }
        let updates = translationUpdates
        try await dbQueue.write { db in
            for record in records {
                try record.insert(db)
            }
            for (id, translatedText) in updates {
                try TranscriptSegmentRecord.updateTranslatedText(
                    translatedText,
                    id: id,
                    in: db
                )
            }
        }

        persistedSegmentIds = nextSegmentIds
        persistedSegmentTranslations = nextTranslations
        pendingTranslations = nextPendingTranslations
    }

    func persistConfirmedSegments(_ segments: [TranscriptSegment]) async throws {
        try await persist(segments.map(TranscriptionEvent.finalized))
    }

    func resetTracking() {
        persistedSegmentIds.removeAll()
        persistedSegmentTranslations.removeAll()
        pendingTranslations.removeAll()
    }
}
