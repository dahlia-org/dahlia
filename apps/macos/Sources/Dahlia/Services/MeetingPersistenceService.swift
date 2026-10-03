import DahliaMeetingAccess
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
    nonisolated let isFirstRecordingSession: Bool
    private(set) var projectId: UUID?
    private(set) var projectName: String?
    private var recordingSession: RecordingSessionRecord
    private let createsMeeting: Bool
    private let resetsRecordingStartOnCancel: Bool
    private let persistencePolicy: TranscriptPersistencePolicy
    private let now: () -> Date
    private nonisolated let transcriptWriter: TranscriptPersistenceWriter

    private init(
        store: TranscriptStore,
        dbQueue: DatabaseQueue,
        meetingId: UUID,
        projectId: UUID?,
        projectName: String?,
        recordingSession: RecordingSessionRecord,
        createsMeeting: Bool,
        resetsRecordingStartOnCancel: Bool,
        existingSegmentIds: Set<UUID>,
        persistencePolicy: TranscriptPersistencePolicy,
        now: @escaping () -> Date = { .now }
    ) {
        self.store = store
        self.dbQueue = dbQueue
        self.meetingId = meetingId
        self.recordingSessionId = recordingSession.id
        self.projectId = projectId
        self.projectName = projectName
        self.recordingSession = recordingSession
        self.isFirstRecordingSession = createsMeeting || resetsRecordingStartOnCancel
        self.createsMeeting = createsMeeting
        self.resetsRecordingStartOnCancel = resetsRecordingStartOnCancel
        self.persistencePolicy = persistencePolicy
        self.now = now
        self.transcriptWriter = TranscriptPersistenceWriter(
            dbQueue: dbQueue,
            meetingId: meetingId,
            recordingSessionId: recordingSession.id,
            persistencePolicy: persistencePolicy,
            existingSegmentIds: existingSegmentIds
        )
        store.upsertRecordingSession(RecordingSessionTimeline(from: recordingSession))
    }

    /// DB transaction を MainActor 外で完了してから、新規ミーティングの UI-facing service を生成する。
    static func createNew(
        store: TranscriptStore,
        dbQueue: DatabaseQueue,
        workspaceId: UUID,
        projectId: UUID?,
        initialName: String,
        allowsCalendarSeriesProjectInheritance: Bool = true,
        calendarEvent: CalendarEvent? = nil,
        recordingSessionId: UUID = .v7(),
        transcriptionMode: TranscriptionMode = .realtime,
        persistencePolicy: TranscriptPersistencePolicy = .streaming,
        now: @escaping () -> Date = { .now }
    ) async throws -> MeetingPersistenceService {
        let meetingId = UUID.v7()
        let startedAt = store.recordingStartTime ?? Date.now
        let prepared = try await MeetingPersistenceStarter.createNew(
            MeetingPersistenceStarter.NewRequest(
                meetingId: meetingId,
                recordingSessionId: recordingSessionId,
                workspaceId: workspaceId,
                requestedProjectId: projectId,
                initialName: initialName,
                allowsCalendarSeriesProjectInheritance: allowsCalendarSeriesProjectInheritance,
                calendarEvent: calendarEvent,
                startedAt: startedAt,
                transcriptionMode: transcriptionMode,
                liveDraft: transcriptionMode == .batch && persistencePolicy == .streaming
            ),
            dbQueue: dbQueue
        )
        return MeetingPersistenceService(
            store: store,
            dbQueue: dbQueue,
            meetingId: meetingId,
            projectId: prepared.projectId,
            projectName: prepared.projectName,
            recordingSession: prepared.recordingSession,
            createsMeeting: true,
            resetsRecordingStartOnCancel: false,
            existingSegmentIds: [],
            persistencePolicy: persistencePolicy,
            now: now
        )
    }

    /// 既存 meeting の読込・時刻補正・session insert を一つの非同期 transaction で行う。
    static func createAppending(
        store: TranscriptStore,
        dbQueue: DatabaseQueue,
        existingMeetingId: UUID,
        recordingStartDate: Date = .now,
        recordingSessionId: UUID = .v7(),
        transcriptionMode: TranscriptionMode = .realtime,
        persistencePolicy: TranscriptPersistencePolicy = .streaming,
        now: @escaping () -> Date = { .now }
    ) async throws -> MeetingPersistenceService {
        let prepared = try await MeetingPersistenceStarter.createAppending(
            MeetingPersistenceStarter.AppendRequest(
                meetingId: existingMeetingId,
                recordingSessionId: recordingSessionId,
                recordingStartDate: recordingStartDate,
                transcriptionMode: transcriptionMode,
                liveDraft: transcriptionMode == .batch && persistencePolicy == .streaming
            ),
            dbQueue: dbQueue
        )

        if !prepared.previousRecordingSessions.isEmpty {
            store.loadRecordingSessions(prepared.previousRecordingSessions.map(RecordingSessionTimeline.init))
        }
        store.recordingStartTime = prepared.resolvedRecordingStartTime

        return MeetingPersistenceService(
            store: store,
            dbQueue: dbQueue,
            meetingId: existingMeetingId,
            projectId: nil,
            projectName: nil,
            recordingSession: prepared.recordingSession,
            createsMeeting: false,
            resetsRecordingStartOnCancel: prepared.resetsRecordingStartOnCancel,
            existingSegmentIds: prepared.existingSegmentIds,
            persistencePolicy: persistencePolicy,
            now: now
        )
    }

    nonisolated func persist(_ event: TranscriptionEvent) async throws {
        try await transcriptWriter.persist(event)
    }

    nonisolated func persist(_ events: [TranscriptionEvent]) async throws {
        try await transcriptWriter.persist(events)
    }

    nonisolated func flushPendingTranscriptEvents() async throws {
        try await transcriptWriter.flushPending()
    }

    nonisolated func persistenceMetricsSnapshot() async -> TranscriptPersistenceWriter.MetricsSnapshot {
        await transcriptWriter.metricsSnapshot()
    }

    /// 最終保存とミーティング完了の記録を行う。
    @discardableResult
    func stop() async -> MeetingPersistenceStopResult {
        let currentDate = now()
        let duration = max(0, currentDate.timeIntervalSince(recordingSession.startedAt))
        recordingSession.endedAt = currentDate
        recordingSession.duration = duration
        recordingSession.updatedAt = currentDate
        do {
            try await transcriptWriter.flushPending()
            let persistedSession = try await MeetingPersistenceFinalizer.finish(
                MeetingPersistenceFinalizer.Request(
                    recordingSessionId: recordingSession.id,
                    meetingId: meetingId,
                    endedAt: currentDate,
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
    func reset() async throws {
        try await transcriptWriter.resetTracking()
    }

    /// 録音開始に失敗したセッションを取り消す。
    func cancel() async {
        let sessionId = recordingSession.id
        let meetingId = meetingId
        let createsMeeting = createsMeeting
        let resetsRecordingStartOnCancel = resetsRecordingStartOnCancel
        let recordingStartedAt = recordingSession.startedAt
        try? await dbQueue.write { db in
            if createsMeeting {
                guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId) else { return }
                try SyncTransactionRecorder.record(
                    workspaceId: meeting.workspaceId,
                    operations: [SyncOperationDraft(entity: .meeting, action: .delete, entityId: meetingId)],
                    in: db
                )
                _ = try MeetingRecord.deleteOne(db, key: meetingId)
            } else {
                let deletedSegmentIds = try UUID.fetchAll(
                    db,
                    sql: "SELECT id FROM transcript_segments WHERE sessionId = ? ORDER BY id",
                    arguments: [sessionId]
                )
                _ = try TranscriptSegmentRecord
                    .filter(Column("sessionId") == sessionId)
                    .deleteAll(db)
                _ = try RecordingSessionRecord.deleteOne(db, key: sessionId)
                if resetsRecordingStartOnCancel {
                    try db.execute(
                        sql: """
                        UPDATE meetings
                        SET recordingStartedAt = NULL
                        WHERE id = ?
                          AND recordingStartedAt = ?
                          AND NOT EXISTS (
                              SELECT 1
                              FROM recording_sessions
                              WHERE recording_sessions.meetingId = meetings.id
                                AND \(RecordingSessionRecord.hasRecordingEvidenceSQL)
                          )
                        """,
                        arguments: [meetingId, recordingStartedAt]
                    )
                }
                guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId) else { return }
                var operations: [SyncOperationDraft] = []
                try TranscriptRecord.finishLive(
                    meetingId: meetingId,
                    sessionId: sessionId,
                    at: Date(),
                    deletions: deletedSegmentIds,
                    in: db
                )
                if resetsRecordingStartOnCancel {
                    try operations.append(SyncInitialSnapshotBuilder.meetingOperation(meeting, action: .update, in: db))
                }
                try SyncTransactionRecorder.record(
                    workspaceId: meeting.workspaceId,
                    operations: operations,
                    in: db
                )
            }
        }
    }

}

/// 録音開始時の DB I/O を MainActor から分離し、開始に必要な値だけを返す。
private enum MeetingPersistenceStarter {
    struct NewRequest {
        let meetingId: UUID
        let recordingSessionId: UUID
        let workspaceId: UUID
        let requestedProjectId: UUID?
        let initialName: String
        let allowsCalendarSeriesProjectInheritance: Bool
        let calendarEvent: CalendarEvent?
        let startedAt: Date
        let transcriptionMode: TranscriptionMode
        var liveDraft = false
    }

    struct NewResult {
        let projectId: UUID?
        let projectName: String?
        let recordingSession: RecordingSessionRecord
    }

    struct AppendRequest {
        let meetingId: UUID
        let recordingSessionId: UUID
        let recordingStartDate: Date
        let transcriptionMode: TranscriptionMode
        var liveDraft = false
    }

    struct AppendResult {
        let recordingSession: RecordingSessionRecord
        let existingSegmentIds: Set<UUID>
        let previousRecordingSessions: [RecordingSessionRecord]
        let resolvedRecordingStartTime: Date
        let resetsRecordingStartOnCancel: Bool
    }

    static func createNew(
        _ request: NewRequest,
        dbQueue: DatabaseQueue
    ) async throws -> NewResult {
        try await dbQueue.write { db in
            if let calendarEvent = request.calendarEvent {
                try CalendarEventRecord.upsert(event: calendarEvent, now: request.startedAt, in: db)
            }
            let projectId = try MeetingRecord.resolvedProjectIdForNewMeeting(
                requestedProjectId: request.requestedProjectId,
                calendarEvent: request.calendarEvent,
                workspaceId: request.workspaceId,
                allowsCalendarSeriesProjectInheritance: request.allowsCalendarSeriesProjectInheritance,
                in: db
            )
            let calendarEventKey = request.calendarEvent?.key
            let meeting = MeetingRecord(
                id: request.meetingId,
                workspaceId: request.workspaceId,
                projectId: projectId,
                name: request.initialName.trimmingCharacters(in: .whitespacesAndNewlines),
                status: request.transcriptionMode == .realtime ? .ready : .transcriptNotFound,
                createdAt: request.startedAt,
                updatedAt: request.startedAt,
                recordingStartedAt: request.startedAt,
                calendarEventIcalUid: calendarEventKey?.icalUid,
                calendarEventRecurrenceId: calendarEventKey?.recurrenceId
            )
            try meeting.insert(db)
            try SyncTransactionRecorder.record(
                workspaceId: request.workspaceId,
                operations: [SyncInitialSnapshotBuilder.meetingOperation(meeting, action: .create, in: db)],
                in: db
            )
            let recordingSession = makeRecordingSession(
                id: request.recordingSessionId,
                meetingId: request.meetingId,
                startedAt: request.startedAt,
                offsetSeconds: 0,
                transcriptionMode: request.transcriptionMode
            )
            try recordingSession.insert(db)
            try TranscriptRecord.beginLive(recordingSession, liveDraft: request.liveDraft, in: db)
            try RecordingArchiveRecord.enqueue(recordingSession, in: db)
            let projectName = try projectId.flatMap { id in
                try ProjectRecord.fetchResolved(id: id, in: db)?.path
            }
            return NewResult(
                projectId: projectId,
                projectName: projectName,
                recordingSession: recordingSession
            )
        }
    }

    static func createAppending(
        _ request: AppendRequest,
        dbQueue: DatabaseQueue
    ) async throws -> AppendResult {
        try await dbQueue.write { db in
            let meeting = try MeetingRecord.fetchOne(db, key: request.meetingId)
            let segments = try Row.fetchAll(
                db,
                sql: "SELECT id, startedAt AS startTime, endedAt AS endTime FROM transcript_segments WHERE meetingId = ? ORDER BY startedAt",
                arguments: [request.meetingId]
            )
            let previousSessions = try RecordingSessionRecord
                .filter(Column("meetingId") == request.meetingId)
                .order(Column("offsetSeconds").asc, Column("startedAt").asc)
                .fetchAll(db)
            let existingRecordingStartTime = try Date.fetchOne(
                db,
                sql: """
                SELECT MIN(recording_sessions.startedAt)
                FROM recording_sessions
                WHERE recording_sessions.meetingId = ?
                  AND \(RecordingSessionRecord.hasRecordingEvidenceSQL)
                """,
                arguments: [request.meetingId]
            )
            let firstSegmentStartTime: Date? = segments.first?["startTime"]
            let lastSegmentEndTime: Date? = segments.last.map { $0["endTime"] ?? $0["startTime"] }
            let resolvedRecordingStartTime = meeting?.recordingStartedAt
                ?? existingRecordingStartTime
                ?? firstSegmentStartTime
                ?? request.recordingStartDate
            let resetsRecordingStartOnCancel = meeting?.recordingStartedAt == nil
                && existingRecordingStartTime == nil
                && firstSegmentStartTime == nil
            if var meetingToUpdate = meeting, meetingToUpdate.recordingStartedAt == nil {
                meetingToUpdate.recordingStartedAt = resolvedRecordingStartTime
                try meetingToUpdate.update(db)
                try SyncTransactionRecorder.record(
                    workspaceId: meetingToUpdate.workspaceId,
                    operations: [SyncInitialSnapshotBuilder.meetingOperation(meetingToUpdate, action: .update, in: db)],
                    in: db
                )
            }

            let recordingSession = makeRecordingSession(
                id: request.recordingSessionId,
                meetingId: request.meetingId,
                startedAt: request.recordingStartDate,
                offsetSeconds: max(meeting?.duration ?? 0, nextOffsetSeconds(
                    sessions: previousSessions,
                    firstSegmentStartTime: firstSegmentStartTime,
                    lastSegmentEndTime: lastSegmentEndTime
                )),
                transcriptionMode: request.transcriptionMode
            )
            try recordingSession.insert(db)
            try TranscriptRecord.beginLive(recordingSession, liveDraft: request.liveDraft, in: db)
            try RecordingArchiveRecord.enqueue(recordingSession, in: db)
            return AppendResult(
                recordingSession: recordingSession,
                existingSegmentIds: Set(segments.map { $0["id"] as UUID }),
                previousRecordingSessions: previousSessions,
                resolvedRecordingStartTime: resolvedRecordingStartTime,
                resetsRecordingStartOnCancel: resetsRecordingStartOnCancel
            )
        }
    }

    private static func nextOffsetSeconds(
        sessions: [RecordingSessionRecord],
        firstSegmentStartTime: Date?,
        lastSegmentEndTime: Date?
    ) -> TimeInterval {
        let sessionDuration = sessions.reduce(0) { total, session in
            total + (
                session.duration
                    ?? session.endedAt.map { max(0, $0.timeIntervalSince(session.startedAt)) }
                    ?? 0
            )
        }
        if sessionDuration > 0 {
            return sessionDuration
        }
        guard let firstSegmentStartTime, let lastSegmentEndTime else { return 0 }
        return max(0, lastSegmentEndTime.timeIntervalSince(firstSegmentStartTime))
    }

    private static func makeRecordingSession(
        id: UUID,
        meetingId: UUID,
        startedAt: Date,
        offsetSeconds: TimeInterval,
        transcriptionMode: TranscriptionMode
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
            transcriptionMode: transcriptionMode
        )
    }
}
