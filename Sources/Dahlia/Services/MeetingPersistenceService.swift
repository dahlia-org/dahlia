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
    private let store: TranscriptStore
    private let dbQueue: DatabaseQueue
    nonisolated let meetingId: UUID
    nonisolated let recordingSessionId: UUID
    private(set) var projectId: UUID?
    private var recordingSession: RecordingSessionRecord
    private let createsMeeting: Bool
    private let persistencePolicy: TranscriptPersistencePolicy
    private nonisolated let transcriptWriter: TranscriptPersistenceWriter

    /// 新規ミーティングを作成して録音を開始する。
    init(
        store: TranscriptStore,
        dbQueue: DatabaseQueue,
        vaultId: UUID,
        projectId: UUID?,
        initialName: String,
        allowsCalendarSeriesProjectInheritance: Bool = true,
        calendarEvent: CalendarEvent? = nil,
        recordingSessionId: UUID = .v7(),
        transcriptionMode: TranscriptionMode = .realtime,
        persistencePolicy: TranscriptPersistencePolicy = .streaming,
        retainAudioAfterBatch: Bool = false
    ) throws {
        self.store = store
        self.dbQueue = dbQueue
        self.meetingId = .v7()
        self.recordingSessionId = recordingSessionId
        self.projectId = projectId
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
        self.transcriptWriter = TranscriptPersistenceWriter(
            dbQueue: dbQueue,
            meetingId: meetingId,
            recordingSessionId: recordingSessionId,
            persistencePolicy: persistencePolicy
        )
        let trimmedInitialName = initialName.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendarEventKey = calendarEvent?.key

        let resolvedProjectId = try dbQueue.write { db in
            if let calendarEvent {
                try CalendarEventRecord.upsert(event: calendarEvent, now: now, in: db)
            }
            let resolvedProjectId = try MeetingRecord.resolvedProjectIdForNewMeeting(
                requestedProjectId: projectId,
                calendarEvent: calendarEvent,
                vaultId: vaultId,
                allowsCalendarSeriesProjectInheritance: allowsCalendarSeriesProjectInheritance,
                in: db
            )
            let meeting = MeetingRecord(
                id: meetingId,
                vaultId: vaultId,
                projectId: resolvedProjectId,
                name: trimmedInitialName,
                status: transcriptionMode == .realtime ? .ready : .transcriptNotFound,
                createdAt: now,
                updatedAt: now,
                calendarEventIcalUid: calendarEventKey?.icalUid,
                calendarEventRecurrenceId: calendarEventKey?.recurrenceId
            )
            try meeting.insert(db)
            try session.insert(db)
            return resolvedProjectId
        }
        self.projectId = resolvedProjectId

        store.upsertRecordingSession(RecordingSessionTimeline(from: session))
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
        self.recordingSessionId = recordingSessionId
        self.projectId = nil
        self.createsMeeting = false
        self.persistencePolicy = persistencePolicy
        let session = Self.makeRecordingSession(
            id: recordingSessionId,
            meetingId: existingMeetingId,
            startedAt: recordingStartDate,
            offsetSeconds: recordingOffsetSeconds,
            transcriptionMode: transcriptionMode,
            retainAudioAfterBatch: retainAudioAfterBatch
        )
        self.recordingSession = session
        self.transcriptWriter = TranscriptPersistenceWriter(
            dbQueue: dbQueue,
            meetingId: existingMeetingId,
            recordingSessionId: recordingSessionId,
            persistencePolicy: persistencePolicy,
            existingSegmentIds: existingSegmentIds
        )

        try dbQueue.write { db in
            try session.insert(db)
        }
        store.upsertRecordingSession(RecordingSessionTimeline(from: session))
    }

    nonisolated func persist(_ event: TranscriptionEvent) async throws {
        try await transcriptWriter.persist(event)
    }

    nonisolated func persist(_ events: [TranscriptionEvent]) async throws {
        try await transcriptWriter.persist(events)
    }

    /// 最終保存とミーティング完了の記録を行う。
    @discardableResult
    func stop() async -> MeetingPersistenceStopResult {
        let finalSegments = persistencePolicy.persistsStreamingSegments
            ? store.segments.filter(\.isConfirmed)
            : []

        let now = Date.now
        let duration = max(0, now.timeIntervalSince(recordingSession.startedAt))
        recordingSession.endedAt = now
        recordingSession.duration = duration
        recordingSession.updatedAt = now
        do {
            try await transcriptWriter.persistConfirmedSegments(finalSegments)
            let persistedSession = try await MeetingPersistenceFinalizer.finish(
                MeetingPersistenceFinalizer.Request(
                    recordingSessionId: recordingSession.id,
                    meetingId: meetingId,
                    endedAt: now,
                    duration: duration,
                    persistsStreamingSegments: persistencePolicy.persistsStreamingSegments
                ),
                dbQueue: dbQueue
            )
            recordingSession = persistedSession
            store.upsertRecordingSession(RecordingSessionTimeline(from: recordingSession))
            return .success
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    /// 保存済みセグメント追跡をリセットする。
    func reset() async {
        await transcriptWriter.resetTracking()
    }

    /// 録音開始に失敗したセッションを取り消す。
    func cancel() async {
        let sessionId = recordingSession.id
        let meetingId = meetingId
        let createsMeeting = createsMeeting
        try? await dbQueue.write { db in
            if createsMeeting {
                _ = try MeetingRecord.deleteOne(db, key: meetingId)
            } else {
                _ = try TranscriptSegmentRecord
                    .filter(Column("sessionId") == sessionId)
                    .deleteAll(db)
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
