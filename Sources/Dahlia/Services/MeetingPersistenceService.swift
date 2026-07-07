import Combine
import Foundation
import GRDB

/// ミーティングの文字起こし結果を GRDB/SQLite にリアルタイム保存するサービス。
/// 確定済みセグメントを差分で INSERT する。
@MainActor
final class MeetingPersistenceService {
    private let store: TranscriptStore
    private let dbQueue: DatabaseQueue
    let meetingId: UUID
    private var cancellable: AnyCancellable?
    private var persistedSegmentIds: Set<UUID> = []
    private var persistedSegmentTranslations: [UUID: String?] = [:]
    private let recordingStartDate: Date

    /// 新規ミーティングを作成して録音を開始する。
    init(
        store: TranscriptStore,
        dbQueue: DatabaseQueue,
        vaultId: UUID,
        projectId: UUID?,
        initialName: String,
        calendarEvent: CalendarEvent? = nil
    ) throws {
        self.store = store
        self.dbQueue = dbQueue
        self.meetingId = .v7()

        let now = store.recordingStartTime ?? Date()
        self.recordingStartDate = now
        let trimmedInitialName = initialName.trimmingCharacters(in: .whitespacesAndNewlines)

        let meeting = MeetingRecord(
            id: meetingId,
            vaultId: vaultId,
            projectId: projectId,
            name: trimmedInitialName,
            status: .ready,
            createdAt: now,
            updatedAt: now
        )
        try dbQueue.write { db in
            try meeting.insert(db)
            if let calendarEvent {
                try CalendarEventRecord(meetingId: meetingId, now: now, event: calendarEvent).insert(db)
            }
        }

        startObserving()
    }

    /// 既存のミーティングに追記する（追記モード）。
    init(store: TranscriptStore, dbQueue: DatabaseQueue, existingMeetingId: UUID, existingSegmentIds: Set<UUID>) {
        self.store = store
        self.dbQueue = dbQueue
        self.meetingId = existingMeetingId
        self.persistedSegmentIds = existingSegmentIds
        self.recordingStartDate = store.recordingStartTime ?? Date()

        startObserving()
    }

    private func startObserving() {
        cancellable = store.$segments
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] segments in
                self?.persistNewConfirmedSegments(segments)
            }
    }

    private func persistNewConfirmedSegments(_ segments: [TranscriptSegment]) {
        var recordsToInsert: [TranscriptSegmentRecord] = []
        var translationUpdates: [(id: UUID, translatedText: String?)] = []

        for segment in segments where segment.isConfirmed {
            if !persistedSegmentIds.contains(segment.id) {
                recordsToInsert.append(TranscriptSegmentRecord(from: segment, meetingId: meetingId))
                persistedSegmentIds.insert(segment.id)
                persistedSegmentTranslations[segment.id] = segment.translatedText
            } else if persistedSegmentTranslations[segment.id] != segment.translatedText {
                persistedSegmentTranslations[segment.id] = segment.translatedText
                translationUpdates.append((id: segment.id, translatedText: segment.translatedText))
            }
        }

        guard !recordsToInsert.isEmpty || !translationUpdates.isEmpty else { return }

        let queue = dbQueue
        Task.detached {
            try? queue.write { db in
                for record in recordsToInsert {
                    try record.insert(db)
                }
                for update in translationUpdates {
                    try db.execute(
                        sql: "UPDATE transcript_segments SET translatedText = ? WHERE id = ?",
                        arguments: [update.translatedText, update.id]
                    )
                }
            }
        }
    }

    /// 監視を停止し、最終保存とミーティング完了の記録を行う。
    func stop() {
        cancellable = nil
        persistNewConfirmedSegments(store.segments)

        let now = Date()
        let duration = now.timeIntervalSince(recordingStartDate)

        try? dbQueue.write { db in
            if var record = try MeetingRecord.fetchOne(db, key: meetingId) {
                record.status = .ready
                record.duration = duration
                record.updatedAt = now
                try record.update(db)
            }
        }
    }

    /// 保存済みセグメント追跡をリセットし、監視を再開する。
    func reset() {
        persistedSegmentIds.removeAll()
        startObserving()
    }
}
