import DahliaRuntimeSupport
import Foundation
import GRDB

/// A fully staged Server snapshot, applied only after an explicit reconnection and a local backup.
struct WorkspaceReconnectionSnapshot: Sendable {
    let store: SyncSnapshotStore
    let cursor: String
    let ids: SyncResetSnapshot
    let projects: [SyncProjectSnapshot]

    /// The caller has durably backed up this Local Workspace and holds its transfer fence.
    /// Snapshot absence is authoritative: it cannot distinguish a deletion from an unuploaded edit.
    func adoptAbsence(workspaceId: UUID, in db: Database) throws {
        try preserveUnsharedAudio(workspaceId: workspaceId, in: db)
        let tables: [(String, String, String, Set<UUID>)] = [
            ("meeting_attachments", "id", "meetingId IN (SELECT id FROM meetings WHERE workspace_id = ?)", ids.screenshots),
            ("summaries", "meetingId", "meetingId IN (SELECT id FROM meetings WHERE workspace_id = ?)", ids.summaries),
            ("transcripts", "meetingId", "meetingId IN (SELECT id FROM meetings WHERE workspace_id = ?)", ids.transcripts),
            ("meetings", "id", "workspace_id = ?", ids.meetings),
            ("files", "id", "workspace_id = ?", ids.files),
        ]
        for (table, key, scope, canonicalIDs) in tables {
            let localIDs = try UUID.fetchAll(db, sql: "SELECT \(key) FROM \(table) WHERE \(scope)", arguments: [workspaceId])
            for id in localIDs where !canonicalIDs.contains(id) {
                if table == "meetings" {
                    try DocumentRetention.archiveBeforeRemoteDeletion(meetingID: id, in: db)
                    try db.execute(sql: "UPDATE document_private_copies SET meetingId = NULL WHERE meetingId = ?", arguments: [id])
                }
                if table == "transcripts" {
                    try db.execute(sql: "DELETE FROM transcript_segments WHERE meetingId = ?", arguments: [id])
                }
                try db.execute(sql: "DELETE FROM \(table) WHERE \(key) = ?", arguments: [id])
            }
        }
    }

    /// Portable backups exclude audio payloads. Keep unshared recordings reachable in a Local
    /// Workspace instead of cascading away their only metadata when adopting Server deletions.
    private func preserveUnsharedAudio(workspaceId: UUID, in db: Database) throws {
        let sessions = try RecordingSessionRecord.fetchAll(db, sql: """
        SELECT s.* FROM recording_sessions s JOIN meetings m ON m.id = s.meetingId
        WHERE m.workspace_id = ? AND (
            EXISTS(SELECT 1 FROM recording_audio_files WHERE recordingSessionId = s.id)
            OR EXISTS(SELECT 1 FROM recording_audio_segments WHERE recordingSessionId = s.id)
            OR EXISTS(SELECT 1 FROM recording_archives WHERE sessionId = s.id AND preparedJSON != '{}'))
        """, arguments: [workspaceId]).filter { !ids.recordings.contains($0.id) }
        for session in sessions {
            // A local-only archive never enters the Server uploader after affiliation changes.
            try db.execute(
                sql: "UPDATE recording_archives SET connectionId = NULL, state = 'saved', retryAt = NULL WHERE sessionId = ?",
                arguments: [session.id]
            )
        }
        let orphaned = sessions.filter { !ids.meetings.contains($0.meetingId) }
        guard !orphaned.isEmpty else { return }
        let recovery = WorkspaceRecord(
            id: .v7(), path: nil, name: L10n.workspaceReconnectionAudio,
            createdAt: .now, lastOpenedAt: .now
        )
        try recovery.insert(db)
        var meetings: [UUID: UUID] = [:]
        for session in orphaned {
            let original = try MeetingRecord.fetchOne(db, key: session.meetingId)
            let meetingId: UUID
            if let existing = meetings[session.meetingId] { meetingId = existing } else {
                meetingId = .v7()
                try MeetingRecord(
                    id: meetingId, workspaceId: recovery.id, projectId: nil,
                    name: original?.name ?? L10n.untitledMeeting, createdAt: .now, updatedAt: .now
                ).insert(db)
                meetings[session.meetingId] = meetingId
            }
            try db.execute(sql: """
            UPDATE recording_audio_files SET original_workspace_path = (SELECT path FROM workspaces WHERE id = ?)
            WHERE recordingSessionId = ? AND storageLocation = 'vault' AND original_workspace_path IS NULL
            """, arguments: [workspaceId, session.id])
            try db.execute(sql: "UPDATE transcript_segments SET sessionId = NULL WHERE sessionId = ?", arguments: [session.id])
            try db.execute(sql: "UPDATE meeting_attachments SET sessionId = NULL WHERE sessionId = ?", arguments: [session.id])
            try db.execute(sql: "UPDATE recording_sessions SET meetingId = ? WHERE id = ?", arguments: [meetingId, session.id])
            try db.execute(sql: """
            UPDATE recording_archives SET meetingId = ?, workspace_id = ?, connectionId = NULL,
                number = NULL, audioJSON = '{}', state = 'saved', retryAt = NULL, failureCode = NULL
            WHERE sessionId = ?
            """, arguments: [meetingId, recovery.id, session.id])
        }
    }

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
        guard try RemoteChangeApplier.applyProjectSnapshot(projects, workspaceId: workspaceId, removeMissing: true, in: db) else {
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
