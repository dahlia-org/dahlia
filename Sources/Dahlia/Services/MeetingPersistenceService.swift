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
    private(set) var projectName: String?
    private var recordingSession: RecordingSessionRecord
    private let createsMeeting: Bool
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
        self.createsMeeting = createsMeeting
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
        vaultId: UUID,
        projectId: UUID?,
        initialName: String,
        allowsCalendarSeriesProjectInheritance: Bool = true,
        calendarEvent: CalendarEvent? = nil,
        recordingSessionId: UUID = .v7(),
        transcriptionMode: TranscriptionMode = .realtime,
        persistencePolicy: TranscriptPersistencePolicy = .streaming,
        retainAudioAfterBatch: Bool = false,
        now: @escaping () -> Date = { .now }
    ) async throws -> MeetingPersistenceService {
        let meetingId = UUID.v7()
        let startedAt = store.recordingStartTime ?? Date.now
        let prepared = try await MeetingPersistenceStarter.createNew(
            MeetingPersistenceStarter.NewRequest(
                meetingId: meetingId,
                recordingSessionId: recordingSessionId,
                vaultId: vaultId,
                requestedProjectId: projectId,
                initialName: initialName,
                allowsCalendarSeriesProjectInheritance: allowsCalendarSeriesProjectInheritance,
                calendarEvent: calendarEvent,
                startedAt: startedAt,
                transcriptionMode: transcriptionMode,
                retainAudioAfterBatch: retainAudioAfterBatch
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
        updatesMeetingStartWhenTranscriptIsEmpty: Bool = false,
        recordingSessionId: UUID = .v7(),
        transcriptionMode: TranscriptionMode = .realtime,
        persistencePolicy: TranscriptPersistencePolicy = .streaming,
        retainAudioAfterBatch: Bool = false,
        now: @escaping () -> Date = { .now }
    ) async throws -> MeetingPersistenceService {
        let prepared = try await MeetingPersistenceStarter.createAppending(
            MeetingPersistenceStarter.AppendRequest(
                meetingId: existingMeetingId,
                recordingSessionId: recordingSessionId,
                recordingStartDate: recordingStartDate,
                existingRecordingStartTime: store.recordingStartTime,
                updatesMeetingStartWhenTranscriptIsEmpty: updatesMeetingStartWhenTranscriptIsEmpty,
                transcriptionMode: transcriptionMode,
                retainAudioAfterBatch: retainAudioAfterBatch
            ),
            dbQueue: dbQueue
        )

        if !prepared.previousRecordingSessions.isEmpty {
            store.loadRecordingSessions(prepared.previousRecordingSessions.map(RecordingSessionTimeline.init))
        }
        if store.recordingStartTime == nil {
            store.recordingStartTime = prepared.resolvedRecordingStartTime
        }

        return MeetingPersistenceService(
            store: store,
            dbQueue: dbQueue,
            meetingId: existingMeetingId,
            projectId: nil,
            projectName: nil,
            recordingSession: prepared.recordingSession,
            createsMeeting: false,
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

}

/// 録音開始時の DB I/O を MainActor から分離し、開始に必要な値だけを返す。
private enum MeetingPersistenceStarter {
    struct NewRequest {
        let meetingId: UUID
        let recordingSessionId: UUID
        let vaultId: UUID
        let requestedProjectId: UUID?
        let initialName: String
        let allowsCalendarSeriesProjectInheritance: Bool
        let calendarEvent: CalendarEvent?
        let startedAt: Date
        let transcriptionMode: TranscriptionMode
        let retainAudioAfterBatch: Bool
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
        let existingRecordingStartTime: Date?
        let updatesMeetingStartWhenTranscriptIsEmpty: Bool
        let transcriptionMode: TranscriptionMode
        let retainAudioAfterBatch: Bool
    }

    struct AppendResult {
        let recordingSession: RecordingSessionRecord
        let existingSegmentIds: Set<UUID>
        let previousRecordingSessions: [RecordingSessionRecord]
        let resolvedRecordingStartTime: Date
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
                vaultId: request.vaultId,
                allowsCalendarSeriesProjectInheritance: request.allowsCalendarSeriesProjectInheritance,
                in: db
            )
            let calendarEventKey = request.calendarEvent?.key
            try MeetingRecord(
                id: request.meetingId,
                vaultId: request.vaultId,
                projectId: projectId,
                name: request.initialName.trimmingCharacters(in: .whitespacesAndNewlines),
                status: request.transcriptionMode == .realtime ? .ready : .transcriptNotFound,
                createdAt: request.startedAt,
                updatedAt: request.startedAt,
                calendarEventIcalUid: calendarEventKey?.icalUid,
                calendarEventRecurrenceId: calendarEventKey?.recurrenceId
            ).insert(db)
            let recordingSession = makeRecordingSession(
                id: request.recordingSessionId,
                meetingId: request.meetingId,
                startedAt: request.startedAt,
                offsetSeconds: 0,
                transcriptionMode: request.transcriptionMode,
                retainAudioAfterBatch: request.retainAudioAfterBatch
            )
            try recordingSession.insert(db)
            let projectName = try projectId.flatMap { id in
                try ProjectRecord.fetchOne(db, key: id)?.name
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
            let segments = try TranscriptSegmentRecord
                .filter(Column("meetingId") == request.meetingId)
                .order(Column("startTime").asc)
                .fetchAll(db)
            let previousSessions = try RecordingSessionRecord
                .filter(Column("meetingId") == request.meetingId)
                .order(Column("offsetSeconds").asc, Column("startedAt").asc)
                .fetchAll(db)
            let firstSegmentStartTime = segments.first?.startTime
            let lastSegmentEndTime = segments.last.map { $0.endTime ?? $0.startTime }
            let resolvedRecordingStartTime: Date
            if let existingRecordingStartTime = request.existingRecordingStartTime {
                resolvedRecordingStartTime = existingRecordingStartTime
            } else if let firstSegmentStartTime {
                resolvedRecordingStartTime = meeting?.createdAt ?? firstSegmentStartTime
            } else {
                resolvedRecordingStartTime = request.recordingStartDate
                if request.updatesMeetingStartWhenTranscriptIsEmpty, var meeting {
                    meeting.createdAt = request.recordingStartDate
                    meeting.updatedAt = request.recordingStartDate
                    try meeting.update(db)
                }
            }

            let recordingSession = makeRecordingSession(
                id: request.recordingSessionId,
                meetingId: request.meetingId,
                startedAt: request.recordingStartDate,
                offsetSeconds: nextOffsetSeconds(
                    sessions: previousSessions,
                    firstSegmentStartTime: firstSegmentStartTime,
                    lastSegmentEndTime: lastSegmentEndTime
                ),
                transcriptionMode: request.transcriptionMode,
                retainAudioAfterBatch: request.retainAudioAfterBatch
            )
            try recordingSession.insert(db)
            return AppendResult(
                recordingSession: recordingSession,
                existingSegmentIds: Set(segments.map(\.id)),
                previousRecordingSessions: previousSessions,
                resolvedRecordingStartTime: resolvedRecordingStartTime
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
        transcriptionMode: TranscriptionMode,
        retainAudioAfterBatch: Bool
    ) -> RecordingSessionRecord {
        let audioRetentionPolicy: RecordingAudioRetentionPolicy? = if transcriptionMode == .batch {
            retainAudioAfterBatch ? .keepInApp : .deleteAfterTranscription
        } else {
            nil
        }
        return RecordingSessionRecord(
            id: id,
            meetingId: meetingId,
            startedAt: startedAt,
            endedAt: nil,
            duration: nil,
            offsetSeconds: offsetSeconds,
            createdAt: startedAt,
            updatedAt: startedAt,
            transcriptionMode: transcriptionMode,
            retainAudioAfterBatch: retainAudioAfterBatch,
            audioRetentionPolicy: audioRetentionPolicy
        )
    }
}
