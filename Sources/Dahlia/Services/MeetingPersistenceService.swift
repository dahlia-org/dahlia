import Combine
import Foundation
import GRDB

enum MeetingPersistenceStopResult {
    case success
    case failure(message: String)

    var succeeded: Bool {
        if case .success = self {
            return true
        }
        return false
    }

    var failureMessage: String? {
        guard case let .failure(message) = self else { return nil }
        return message
    }
}

/// ミーティングの文字起こし結果を GRDB/SQLite にリアルタイム保存するサービス。
/// 確定済みセグメントを差分で INSERT する。
@MainActor
final class MeetingPersistenceService {
    private enum StopError: LocalizedError {
        case recordingSessionMissing

        var errorDescription: String? {
            L10n.recordingSessionNotActive
        }
    }

    private let store: TranscriptStore
    private let dbQueue: DatabaseQueue
    let meetingId: UUID
    private var cancellable: AnyCancellable?
    private var persistedSegmentIds: Set<UUID> = []
    private var persistedSegmentTranslations: [UUID: String?] = [:]
    private var recordingSession: RecordingSessionRecord
    private let createsMeeting: Bool
    private let persistencePolicy: TranscriptPersistencePolicy

    var recordingSessionId: UUID {
        recordingSession.id
    }

    /// 新規ミーティングを作成して録音を開始する。
    init(
        store: TranscriptStore,
        dbQueue: DatabaseQueue,
        vaultId: UUID,
        projectId: UUID?,
        initialName: String,
        calendarEvent: CalendarEvent? = nil,
        recordingSessionId: UUID = .v7(),
        transcriptionMode: TranscriptionMode = .realtime,
        persistencePolicy: TranscriptPersistencePolicy = .streaming,
        retainAudioAfterBatch: Bool = false
    ) throws {
        self.store = store
        self.dbQueue = dbQueue
        self.meetingId = .v7()
        self.createsMeeting = true
        self.persistencePolicy = persistencePolicy

        let now = store.recordingStartTime ?? Date()
        let session = Self.makeRecordingSession(
            id: recordingSessionId,
            meetingId: meetingId,
            startedAt: now,
            offsetSeconds: 0,
            transcriptionMode: transcriptionMode,
            retainAudioAfterBatch: retainAudioAfterBatch
        )
        self.recordingSession = session
        let trimmedInitialName = initialName.trimmingCharacters(in: .whitespacesAndNewlines)

        let meeting = MeetingRecord(
            id: meetingId,
            vaultId: vaultId,
            projectId: projectId,
            name: trimmedInitialName,
            status: transcriptionMode == .realtime ? .ready : .transcriptNotFound,
            createdAt: now,
            updatedAt: now
        )
        try dbQueue.write { db in
            try meeting.insert(db)
            try session.insert(db)
            if let calendarEvent {
                try CalendarEventRecord(meetingId: meetingId, now: now, event: calendarEvent).insert(db)
            }
        }

        store.upsertRecordingSession(RecordingSessionTimeline(from: session))
        startObserving()
    }

    /// 既存のミーティングに追記する（追記モード）。
    init(
        store: TranscriptStore,
        dbQueue: DatabaseQueue,
        existingMeetingId: UUID,
        existingSegmentIds: Set<UUID>,
        recordingStartDate: Date = Date(),
        recordingOffsetSeconds: TimeInterval = 0,
        recordingSessionId: UUID = .v7(),
        transcriptionMode: TranscriptionMode = .realtime,
        persistencePolicy: TranscriptPersistencePolicy = .streaming,
        retainAudioAfterBatch: Bool = false
    ) throws {
        self.store = store
        self.dbQueue = dbQueue
        self.meetingId = existingMeetingId
        self.createsMeeting = false
        self.persistencePolicy = persistencePolicy
        self.persistedSegmentIds = existingSegmentIds
        let session = Self.makeRecordingSession(
            id: recordingSessionId,
            meetingId: existingMeetingId,
            startedAt: recordingStartDate,
            offsetSeconds: recordingOffsetSeconds,
            transcriptionMode: transcriptionMode,
            retainAudioAfterBatch: retainAudioAfterBatch
        )
        self.recordingSession = session

        try dbQueue.write { db in
            try session.insert(db)
        }
        store.upsertRecordingSession(RecordingSessionTimeline(from: session))
        startObserving()
    }

    private func startObserving() {
        guard persistencePolicy.persistsStreamingSegments else { return }
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
                recordsToInsert.append(TranscriptSegmentRecord(from: segment, meetingId: meetingId, defaultSessionId: recordingSession.id))
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
    @discardableResult
    func stop() -> MeetingPersistenceStopResult {
        cancellable = nil
        let finalSegmentRecords = persistencePolicy.persistsStreamingSegments
            ? store.segments
            .filter(\.isConfirmed)
            .map { TranscriptSegmentRecord(from: $0, meetingId: meetingId, defaultSessionId: recordingSession.id) }
            : []

        let now = Date.now
        let duration = max(0, now.timeIntervalSince(recordingSession.startedAt))
        recordingSession.endedAt = now
        recordingSession.duration = duration
        recordingSession.updatedAt = now

        do {
            let persistedSession = try dbQueue.write { db -> RecordingSessionRecord in
                // debounce中だった最終セグメントもsession終了と同じtransactionで確定する。
                for record in finalSegmentRecords {
                    if let existing = try TranscriptSegmentRecord.fetchOne(db, key: record.id) {
                        // 既存行のmeeting/session/timeは変更せず、この録音中に更新され得る翻訳だけを反映する。
                        if existing.translatedText != record.translatedText {
                            try db.execute(
                                sql: "UPDATE transcript_segments SET translatedText = ? WHERE id = ?",
                                arguments: [record.translatedText, record.id]
                            )
                        }
                    } else {
                        try record.insert(db)
                    }
                }
                // バッチ処理が先に記録したエラーや試行情報を、録音開始時点の値で上書きしない。
                try db.execute(
                    sql: """
                    UPDATE recording_sessions
                    SET endedAt = ?, duration = ?, updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [now, duration, now, recordingSession.id]
                )
                let totalDuration = try Double.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(duration), 0) FROM recording_sessions WHERE meetingId = ?",
                    arguments: [meetingId]
                ) ?? duration
                if var record = try MeetingRecord.fetchOne(db, key: meetingId) {
                    if persistencePolicy.persistsStreamingSegments {
                        record.status = .ready
                    }
                    record.duration = totalDuration
                    record.updatedAt = now
                    try record.update(db)
                }
                guard let persistedSession = try RecordingSessionRecord.fetchOne(db, key: recordingSession.id) else {
                    throw StopError.recordingSessionMissing
                }
                return persistedSession
            }
            recordingSession = persistedSession
            store.upsertRecordingSession(RecordingSessionTimeline(from: recordingSession))
            return .success
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    /// 保存済みセグメント追跡をリセットし、監視を再開する。
    func reset() {
        persistedSegmentIds.removeAll()
        startObserving()
    }

    /// 録音開始に失敗したセッションを取り消す。
    func cancel() {
        cancellable = nil
        let sessionId = recordingSession.id
        let meetingId = meetingId
        let createsMeeting = createsMeeting
        try? dbQueue.write { db in
            if createsMeeting {
                _ = try MeetingRecord.deleteOne(db, key: meetingId)
            } else {
                _ = try RecordingSessionRecord.deleteOne(db, key: sessionId)
            }
        }
    }

    private static func makeRecordingSession(
        id: UUID,
        meetingId: UUID,
        startedAt: Date,
        offsetSeconds: TimeInterval,
        transcriptionMode: TranscriptionMode,
        retainAudioAfterBatch: Bool
    ) -> RecordingSessionRecord {
        RecordingSessionRecord(
            id: id,
            meetingId: meetingId,
            startedAt: startedAt,
            endedAt: nil,
            duration: nil,
            offsetSeconds: offsetSeconds,
            createdAt: startedAt,
            updatedAt: startedAt,
            transcriptionMode: transcriptionMode,
            retainAudioAfterBatch: retainAudioAfterBatch
        )
    }
}
