import DahliaRuntimeSupport
import Foundation
import GRDB

/// A fully staged Server snapshot, applied only after an explicit reconnection and a local backup.
struct WorkspaceReconnectionSnapshot: Sendable {
    let store: SyncSnapshotStore
    let cursor: String
    let ids: SyncResetSnapshot
    let projects: [SyncProjectSnapshot]

    func apply(workspaceId: UUID, advanceCursor: Bool, in db: Database) throws {
        // IDs are global in SQLite. Never attach another Workspace's records to this connection.
        try store.forEachChange { change in
            switch change.entity {
            case .workspace:
                guard change.entityId == workspaceId else { throw LocalWorkspaceImportError.collision }
            case .project, .meeting, .file:
                let table = change.entity == .project ? "projects" : change.entity == .meeting ? "meetings" : "files"
                if let owner = try UUID.fetchOne(db, sql: "SELECT workspace_id FROM \(table) WHERE id = ?", arguments: [change.entityId]),
                   owner != workspaceId { throw LocalWorkspaceImportError.collision }
            case .meetingAttachment, .recording:
                guard let parent = change.record?.meetingId, ids.meetings.contains(parent) else { throw SyncTransactionQueueError.invalidReceipt }
                let table = change.entity == .recording ? "recording_sessions" : "meeting_attachments"
                if let meeting = try UUID.fetchOne(db, sql: "SELECT meetingId FROM \(table) WHERE id = ?", arguments: [change.entityId]),
                   meeting != change.record?.meetingId { throw LocalWorkspaceImportError.collision }
            case .summary, .transcript:
                guard ids.meetings.contains(change.entityId) else { throw SyncTransactionQueueError.invalidReceipt }
            case .meetingEvent: break
            }
        }
        guard try RemoteChangeApplier.applyProjectSnapshot(projects, workspaceId: workspaceId, removeMissing: false, in: db) else {
            throw LocalWorkspaceImportError.changed
        }
        try store.forEachChange { change in
            guard change.entity != .project, let record = change.record, let revision = change.revision else { return }
            if change.entity == .recording {
                // Keep retained local audio and preparations; canonical audio is installed by the normal applier.
                try db.execute(
                    sql: "UPDATE recording_archives SET connectionId = ?, state = 'remote', retryAt = NULL, failureCode = NULL WHERE sessionId = ? AND workspace_id = ?",
                    arguments: [WorkspaceRecord.fetchOne(db, key: workspaceId)?.accountConnectionId, change.entityId, workspaceId]
                )
            }
            if change.entity == .summary || change.entity == .transcript || change.entity == .file {
                // The old Local body is in the backup. Do not present it as the newly confirmed Server revision.
                let entity = change.entity == .summary ? TextContentEntity.summary : change.entity == .transcript ? .transcript : .file
                try TextContentStore.releaseBody(entity: entity, id: change.entityId, in: db)
                if change.entity == .summary { try SummaryExportRecord.filter(Column("meetingId") == change.entityId).deleteAll(db) }
            }
            try RemoteChangeApplier.upsert(change, record: record, screenshots: [:], transcripts: [:], workspaceId: workspaceId, in: db)
            if change.entity == .meeting, record.hasSummary == false, let summaryRevision = record.summaryRevision, summaryRevision > 0 {
                // A deleted Server summary is not a never-uploaded summary. Preserve the local version
                // in the backup, adopt the deletion, and retain its revision for future explicit edits.
                var absent = record
                absent.contentOmitted = true
                absent.contentPresent = false
                try SyncTransactionQueue.applyCanonical(
                    .summary,
                    id: change.entityId,
                    workspaceId: workspaceId,
                    value: absent,
                    remoteRevision: summaryRevision,
                    in: db
                )
                try SummaryExportRecord.filter(Column("meetingId") == change.entityId).deleteAll(db)
                try db.execute(sql: """
                INSERT INTO sync_entity_state(workspace_id, entity, entityId, confirmedRevision) VALUES (?, 'summary', ?, ?)
                ON CONFLICT(workspace_id, entity, entityId) DO UPDATE SET confirmedRevision = excluded.confirmedRevision
                """, arguments: [workspaceId, change.entityId, summaryRevision])
            }
            try db.execute(sql: """
            INSERT INTO sync_entity_state(workspace_id, entity, entityId, confirmedRevision) VALUES (?, ?, ?, ?)
            ON CONFLICT(workspace_id, entity, entityId) DO UPDATE SET confirmedRevision = excluded.confirmedRevision
            """, arguments: [workspaceId, change.entity, change.entityId, revision])
        }
        try db.execute(sql: "UPDATE workspaces SET syncRecoveryState = NULL, syncPullErrorJSON = NULL WHERE id = ?", arguments: [workspaceId])
        // An existing destination must still consume deletions since its own cursor. The staged
        // snapshot contains only live records and must not make those deletion events disappear.
        if advanceCursor {
            try db.execute(sql: "UPDATE workspaces SET syncPullCursor = ? WHERE id = ?", arguments: [cursor, workspaceId])
        }
    }
}
