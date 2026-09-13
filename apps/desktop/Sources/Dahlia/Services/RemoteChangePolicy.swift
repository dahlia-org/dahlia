import Foundation
import GRDB

/// Shared by incremental sync and revision-bound body reads. Recovery and eviction are separate, stricter operations.
enum RemoteChangePolicy {
    struct Context: Sendable {
        let workspaceId: UUID
        let connectionId: UUID
        let generation: Int64

        func isCurrent(in db: Database) throws -> Bool {
            try SyncTransactionQueue.matchesExpectedConnection(workspaceId: workspaceId, connectionId: connectionId, in: db)
                && Int64.fetchOne(
                    db,
                    sql: "SELECT syncMutationGeneration FROM workspaces WHERE id = ? AND syncRecoveryState IS NULL",
                    arguments: [workspaceId]
                ) == generation
        }
    }

    enum Result: Equatable, Sendable {
        case applied, alreadyApplied, deferred, retry
    }

    static func decision(_ change: SyncChangePage.Change, context: Context, in db: Database) throws -> Result {
        guard try context.isCurrent(in: db) else { return .retry }
        if change.action == "upsert" {
            guard let record = change.record, change.revision != nil else { throw SyncTransactionQueueError.invalidReceipt }
            if [.summary, .transcript, .file].contains(change.entity), record.contentOmitted != true {
                throw SyncTransactionQueueError.invalidReceipt
            }
        }
        guard change.action != "reset", try permits(
            change.entity,
            id: change.entityId,
            action: change.action,
            record: change.record,
            workspaceId: context.workspaceId,
            in: db
        ) else { return .deferred }
        if change.action == "upsert", let incoming = change.revision,
           let confirmed = try Int.fetchOne(
               db,
               sql: "SELECT confirmedRevision FROM sync_entity_state WHERE workspace_id = ? AND entity = ? AND entityId = ?",
               arguments: [context.workspaceId, change.entity, change.entityId]
           ), confirmed >= incoming {
            // Changes carry current canonical records, not historical bodies. A decrease may be a coalesced delete/recreate.
            return confirmed == incoming ? .alreadyApplied : .retry
        }
        return .applied
    }

    private struct Key: Hashable {
        let entity: SyncEntity
        let id: UUID
    }

    /// Relationships include both the stored and incoming parents, so moves and queued deletions cannot evade protection.
    private static func references(_ entity: SyncEntity, id: UUID, record: SyncCanonicalPayload?, in db: Database) throws -> Set<Key> {
        var keys: Set<Key> = [.init(entity: entity, id: id)]
        var meetings: Set<UUID> = []
        var projects: Set<UUID> = []
        switch entity {
        case .workspace: break
        case .recording:
            if let session = try RecordingSessionRecord.fetchOne(db, key: id) { meetings.insert(session.meetingId) }
            if let meeting = record?.meetingId { meetings.insert(meeting) }
        case .meetingEvent:
            if let meeting = record?.meetingId { meetings.insert(meeting) }
        case .project:
            projects.insert(id)
            if let parent = record?.parentProjectId { projects.insert(parent) }
        case .meeting:
            meetings.insert(id)
            if let project = record?.projectId { projects.insert(project) }
        case .summary, .transcript:
            meetings.insert(id)
        case .file:
            try meetings.formUnion(UUID.fetchAll(db, sql: "SELECT meetingId FROM meeting_attachments WHERE fileId = ?", arguments: [id]))
        case .meetingAttachment:
            if let link = try MeetingAttachmentRecord.fetchOne(db, key: id) {
                meetings.insert(link.meetingId)
                keys.insert(.init(entity: .file, id: link.fileId))
            }
            if let meeting = record?.meetingId { meetings.insert(meeting) }
            if let file = record?.fileId { keys.insert(.init(entity: .file, id: file)) }
        }
        for meeting in meetings {
            keys.insert(.init(entity: .meeting, id: meeting))
            if let project = try MeetingRecord.fetchOne(db, key: meeting)?.projectId { projects.insert(project) }
        }
        for project in projects {
            keys.insert(.init(entity: .project, id: project))
            if let parent = try ProjectRecord.fetchOne(db, key: project)?.parentProjectId {
                keys.insert(.init(entity: .project, id: parent))
            }
        }
        return keys
    }

    static func permits(
        _ entity: SyncEntity,
        id: UUID,
        action: String = "upsert",
        record: SyncCanonicalPayload? = nil,
        workspaceId: UUID,
        in db: Database
    ) throws -> Bool {
        guard try String.fetchOne(db, sql: "SELECT syncRecoveryState FROM workspaces WHERE id = ?", arguments: [workspaceId]) == nil
        else { return false }
        let key = Key(entity: entity, id: id)
        let related = try references(entity, id: id, record: record, in: db)
        let destructive = action == "delete" || action == "reset"
        if entity == .file, destructive,
           try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM meeting_attachments WHERE fileId = ?)", arguments: [id]) == true { return false }
        let pending = try Row.fetchCursor(db, sql: """
        SELECT o.entity, o.entityId, o.action, o.payloadJSON
        FROM sync_operations o JOIN sync_transactions t ON t.id = o.transactionId
        WHERE t.workspace_id = ? AND (
            o.entity = 'workspace' OR o.entity = ? AND o.entityId = ?
            OR o.action IN ('delete', 'reset', 'create') OR ?
            OR ? AND o.entity = 'meeting_attachment' OR ? AND o.entity = 'file'
        )
        """, arguments: [
            workspaceId,
            entity,
            id,
            destructive || entity == .project || entity == .workspace,
            entity == .file,
            entity == .meetingAttachment,
        ])
        while let row = try pending.next() {
            let localEntity: SyncEntity = row["entity"]
            let localId: UUID = row["entityId"]
            let localAction: String = row["action"]
            let localKey = Key(entity: localEntity, id: localId)
            if entity == .workspace || localEntity == .workspace || key == localKey { return false }
            if localAction == "delete" || localAction == "reset" || localAction == "create", related.contains(localKey) { return false }
            if entity == .meetingAttachment, localEntity == .file, related.contains(localKey) { return false }
            guard destructive || entity == .project || (entity == .file && localEntity == .meetingAttachment) else { continue }
            let payload: String? = row["payloadJSON"]
            let localRecord = try payload.map { try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: Data($0.utf8)) }
            let localReferences = try references(localEntity, id: localId, record: localRecord, in: db)
            if localReferences.contains(key) { return false }
        }
        let activeMeetings = try UUID.fetchAll(db, sql: "SELECT DISTINCT meetingId FROM recording_sessions WHERE endedAt IS NULL")
        for meeting in activeMeetings {
            if entity == .transcript, id == meeting { return false }
            if entity == .file, related.contains(.init(entity: .meeting, id: meeting)),
               let checksum = record?.checksum, let file = try FileRecord.fetchOne(db, key: id), checksum != file.checksum { return false }
            if entity == .meetingAttachment, related.contains(.init(entity: .meeting, id: meeting)),
               let record, let link = try MeetingAttachmentRecord.fetchOne(db, key: id),
               record.fileId != link.fileId || record.meetingId != link.meetingId || record.sessionId != link.sessionId || record.capturedAt != link
               .capturedAt { return false }
            if destructive {
                if entity == .workspace,
                   try MeetingRecord.fetchOne(db, key: meeting)?.workspaceId == workspaceId { return false }
                if related.contains(.init(entity: .meeting, id: meeting)) { return false }
                if entity == .project, try references(.meeting, id: meeting, record: nil, in: db).contains(key) { return false }
            }
        }
        return true
    }
}
