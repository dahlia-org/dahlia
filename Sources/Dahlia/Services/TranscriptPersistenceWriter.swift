import Foundation
import GRDB

/// 確定済み文字起こしを MainActor に依存せず、順序を保って SQLite へ保存する。
actor TranscriptPersistenceWriter {
    private let dbQueue: DatabaseQueue
    private let meetingId: UUID
    private let recordingSessionId: UUID
    private let persistencePolicy: TranscriptPersistencePolicy

    private var persistedSegmentIds: Set<UUID>
    private var persistedSegmentTranslations: [UUID: String?] = [:]
    private var pendingTranslations: [UUID: String?] = [:]

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
        guard persistencePolicy.persistsStreamingSegments else { return }

        switch event {
        case let .finalized(segment):
            try await persistConfirmedSegments([segment])
        case let .translation(_, segmentID, translatedText):
            try await persistTranslation(segmentID: segmentID, translatedText: translatedText)
        case .preview, .clearPreview, .failure:
            break
        }
    }

    func persistConfirmedSegments(_ segments: [TranscriptSegment]) async throws {
        guard persistencePolicy.persistsStreamingSegments else { return }
        try Task.checkCancellation()

        let confirmedSegments = segments.filter(\.isConfirmed)
        guard !confirmedSegments.isEmpty else { return }

        var recordsToInsert: [TranscriptSegmentRecord] = []
        var translationUpdates: [(id: UUID, translatedText: String?)] = []

        for var segment in confirmedSegments {
            if let pendingTranslation = pendingTranslations.removeValue(forKey: segment.id) {
                segment.translatedText = pendingTranslation
            }

            if persistedSegmentIds.insert(segment.id).inserted {
                recordsToInsert.append(TranscriptSegmentRecord(
                    from: segment,
                    meetingId: meetingId,
                    defaultSessionId: recordingSessionId
                ))
            } else if persistedSegmentTranslations[segment.id] != segment.translatedText {
                translationUpdates.append((id: segment.id, translatedText: segment.translatedText))
            }
        }

        let records = recordsToInsert
        let updates = translationUpdates
        do {
            try await dbQueue.write { db in
                for record in records {
                    try record.insert(db)
                }
                for update in updates {
                    try TranscriptSegmentRecord.updateTranslatedText(
                        update.translatedText,
                        id: update.id,
                        in: db
                    )
                }
            }
            for record in records {
                persistedSegmentTranslations[record.id] = record.translatedText
            }
            for update in updates {
                persistedSegmentTranslations[update.id] = update.translatedText
            }
        } catch {
            for record in records {
                persistedSegmentIds.remove(record.id)
            }
            throw error
        }
    }

    func resetTracking() {
        persistedSegmentIds.removeAll()
        persistedSegmentTranslations.removeAll()
        pendingTranslations.removeAll()
    }

    private func persistTranslation(segmentID: UUID, translatedText: String?) async throws {
        guard persistedSegmentIds.contains(segmentID) else {
            pendingTranslations[segmentID] = translatedText
            return
        }
        guard persistedSegmentTranslations[segmentID] != translatedText else { return }

        try await dbQueue.write { db in
            try TranscriptSegmentRecord.updateTranslatedText(
                translatedText,
                id: segmentID,
                in: db
            )
        }
        persistedSegmentTranslations[segmentID] = translatedText
    }
}
