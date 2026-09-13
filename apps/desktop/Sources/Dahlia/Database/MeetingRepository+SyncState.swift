import DahliaRuntimeSupport
import Foundation
import GRDB

enum MeetingSyncState: Equatable, Sendable {
    case local
    case pending
    case synced
    case recovering
    case updateRequired
    case relocationPaused
    case blocked(SyncBlockedReason)
}

struct MeetingSyncSnapshot: Equatable, Sendable {
    struct Revision: FetchableRecord, Decodable, Equatable, Sendable {
        let entity: String
        let entityId: UUID
        let confirmedRevision: Int?
    }

    let connectionId: UUID?
    let state: MeetingSyncState
    let revisions: [Revision]
    var content: [Content] = []
    var recordingArchiveState: String?

    struct Content: FetchableRecord, Decodable, Equatable, Sendable {
        let entity: String
        let entityId: UUID
        let residentRevision: Int?
        let complete: Bool
        let present: Bool
        let contentCount: Int?
        let fetchError: String?
    }
}

extension MeetingRepository {
    /// Only observes sync metadata. It never reads a transcript or image body to detect changes.
    nonisolated static func fetchMeetingSyncSnapshot(
        meetingId: UUID,
        in db: Database
    ) throws -> MeetingSyncSnapshot? {
        guard let meeting = try MeetingRecord.fetchOne(db, key: meetingId),
              let workspace = try WorkspaceRecord.fetchOne(db, key: meeting.workspaceId) else { return nil }
        let archiveStates = try String.fetchAll(db, sql: """
        SELECT a.state FROM recording_archives a JOIN recording_sessions s ON s.id = a.sessionId
        WHERE a.meetingId = ? AND a.connectionId IS ? AND s.endedAt IS NOT NULL AND a.state <> 'expired'
        """, arguments: [meetingId, workspace.accountConnectionId])
        let archiveState: String? = archiveStates.isEmpty ? nil : archiveStates.contains("failed") ? "failed"
            : archiveStates.allSatisfy { ["saved", "remote"].contains($0) } ? "saved" : "pending"
        guard let connectionId = workspace.accountConnectionId else {
            return MeetingSyncSnapshot(connectionId: nil, state: .local, revisions: [], recordingArchiveState: archiveState)
        }
        let state = try fetchWorkspaceSyncState(workspace, in: db)
        let revisions = try MeetingSyncSnapshot.Revision.fetchAll(
            db,
            sql: """
            SELECT entity, entityId, confirmedRevision FROM sync_entity_state
            WHERE workspace_id = ? AND (
                (entity IN ('meeting', 'summary', 'transcript') AND entityId = ?)
                OR (entity = 'meeting_attachment' AND entityId IN (SELECT id FROM meeting_attachments WHERE meetingId = ?))
                OR (entity = 'file' AND entityId IN (SELECT fileId FROM meeting_attachments WHERE meetingId = ?))
            ) ORDER BY entity, entityId
            """,
            arguments: [workspace.id, meetingId, meetingId, meetingId]
        )
        let content = try MeetingSyncSnapshot.Content.fetchAll(db, sql: """
        SELECT entity, entityId, residentRevision, complete, present, contentCount, fetchError FROM sync_content_state
        WHERE workspace_id = ? AND (entityId = ? AND entity IN ('summary', 'transcript')
          OR entity = 'file' AND entityId IN (SELECT fileId FROM meeting_attachments WHERE meetingId = ?))
        ORDER BY entity, entityId
        """, arguments: [workspace.id, meetingId, meetingId])
        return MeetingSyncSnapshot(
            connectionId: connectionId,
            state: state,
            revisions: revisions,
            content: content,
            recordingArchiveState: archiveState
        )
    }

    nonisolated static func fetchWorkspaceSyncState(_ workspace: WorkspaceRecord, in db: Database) throws -> MeetingSyncState {
        guard let connectionId = workspace.accountConnectionId else { return .local }
        let blocked = try String.fetchOne(
            db,
            sql: "SELECT blockedReason FROM sync_transactions WHERE workspace_id = ? AND blockedReason IS NOT NULL ORDER BY sequence LIMIT 1",
            arguments: [workspace.id]
        ).flatMap(SyncBlockedReason.init(rawValue:))
        let hasPending = try SyncTransactionQueue.hasPending(workspaceId: workspace.id, in: db)
        return if let blocked {
            .blocked(blocked)
        } else if workspace.syncRecoveryState == "transferBlocked" {
            .relocationPaused
        } else if workspace.syncRecoveryState == "updateRequired" {
            .updateRequired
        } else if workspace.syncRecoveryState != nil {
            .recovering
        } else if workspace.syncConfirmedConnectionId != connectionId || workspace.syncPullCursor == nil
            || hasPending {
            .pending
        } else {
            .synced
        }
    }

    nonisolated static func fetchAccountSyncStates(in db: Database) throws -> [UUID: MeetingSyncState] {
        let workspaces = try WorkspaceRecord.filter(Column("accountConnectionId") != nil).fetchAll(db)
        var states: [UUID: MeetingSyncState] = [:]
        for workspace in workspaces {
            guard let connectionId = workspace.accountConnectionId else { continue }
            let state = try fetchWorkspaceSyncState(workspace, in: db)
            if states[connectionId].map({ $0.accountPriority < state.accountPriority }) ?? true {
                states[connectionId] = state
            }
        }
        return states
    }

}

extension MeetingSyncState {
    var accountPriority: Int {
        switch self {
        case .local: 0
        case .synced: 1
        case .pending: 2
        case .recovering: 3
        case .updateRequired, .relocationPaused: 4
        case .blocked(.validation): 5
        case .blocked(.conflict): 6
        case .blocked(.authorization): 7
        }
    }
}

extension MeetingRepository {
    nonisolated func retryRecordingArchives(meetingId: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
            UPDATE recording_archives SET state = 'pending', retryAt = NULL, failureCode = NULL
            WHERE meetingId = ? AND state = 'failed'
              AND EXISTS (SELECT 1 FROM workspaces v WHERE v.id = recording_archives.workspace_id
                AND v.accountConnectionId IS recording_archives.connectionId
                AND (v.accountConnectionId IS NULL OR v.syncRole IN ('admin', 'editor')) AND v.syncRecoveryState IS NULL)
            """, arguments: [meetingId])
        }
    }
}
