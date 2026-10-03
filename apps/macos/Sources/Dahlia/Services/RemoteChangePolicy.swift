import Foundation
import GRDB

/// Shared by incremental sync and revision-bound body reads. Recovery and eviction are separate, stricter operations.
enum RemoteChangePolicy {
    struct Context: Sendable {
        let workspaceId: UUID
        let connectionId: UUID
        let generation: Int64
        var lifecycleGeneration: Int64?

        func isCurrent(in db: Database) throws -> Bool {
            let column = lifecycleGeneration == nil ? "syncMutationGeneration" : "syncLifecycleGeneration"
            return try SyncTransactionQueue.matchesExpectedConnection(workspaceId: workspaceId, connectionId: connectionId, in: db)
                && Int64.fetchOne(
                    db,
                    sql: "SELECT \(column) FROM workspaces WHERE id = ? AND syncRecoveryState IS NULL",
                    arguments: [workspaceId]
                ) == (lifecycleGeneration ?? generation)
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
            if confirmed > incoming { return .retry }
            if try !SyncReconciliation.contains(change.entity, id: change.entityId, workspaceId: context.workspaceId, in: db) {
                return .alreadyApplied
            }
        }
        return .applied
    }

    private struct Key: Hashable {
        let entity: SyncEntity
        let id: UUID
    }

    /// Durable operation bodies and canonical API records have different content/metadata schemas.
    /// Conflict checks decode only relationships, without interpreting unrelated payload fields.
    private struct References: Decodable {
        let parentProjectId: UUID?
        let projectId: UUID?
        let meetingId: UUID?
        let fileId: UUID?

        init(_ record: SyncCanonicalPayload) {
            parentProjectId = record.parentProjectId
            projectId = record.projectId
            meetingId = record.meetingId
            fileId = record.fileId
        }
    }

    /// Relationships include both the stored and incoming parents, so moves and queued deletions cannot evade protection.
    private static func references(_ entity: SyncEntity, id: UUID, record: References?, in db: Database) throws -> Set<Key> {
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
        let related = try references(entity, id: id, record: record.map(References.init), in: db)
        let destructive = action == "delete" || action == "reset"
        if entity == .file, destructive,
           try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM meeting_attachments WHERE fileId = ?)", arguments: [id]) == true { return false }
        // Unknown legacy requests remain a barrier until indexed. Known requests use only
        // durable resource keys, so a bulk attachment import cannot cause per-change JSON scans.
        if try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM sync_transactions WHERE workspace_id = ? AND dependenciesReady = 0)
          OR EXISTS(SELECT 1 FROM sync_dependency_keys WHERE resource = ? AND exclusive = 1)
        """, arguments: [workspaceId, "workspace:\(workspaceId.uuidString.lowercased())"]) == true { return false }
        if entity == .workspace, try SyncTransactionQueue.hasPending(workspaceId: workspaceId, in: db) { return false }
        if try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sync_dependency_keys WHERE resource = ?)",
            arguments: ["entity:\(SyncDependencies.key(entity, id))"]
        ) == true { return false }
        for reference in related.union([key]) {
            let protectAllReferences = reference == key && (destructive || entity == .project || entity == .file)
                || entity == .meetingAttachment && reference.entity == .file
            if try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM sync_dependency_keys WHERE resource = ? AND (exclusive = 1 OR ?))
            """, arguments: ["exists:\(SyncDependencies.key(reference.entity, reference.id))", protectAllReferences]) == true { return false }
        }
        // These sources are durable but their initial requests have not been constructed yet.
        if try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM sync_initial_entities WHERE workspaceId = ? AND built = 0
          AND ((entity = ? AND entityId = ?) OR ?))
        """, arguments: [workspaceId, entity, id, destructive]) == true { return false }
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
