import Foundation
import GRDB

/// Durable read/exclusive resource sets describe ordering, not ownership or authorization.
/// Entity writes are exclusive; references share an existence key unless that entity moves or disappears.
enum SyncDependencies {
    private struct Relations: Decodable {
        var parentProjectId: UUID?
        var projectId: UUID?
        var meetingId: UUID?
        var fileId: UUID?
    }

    static func key(_ entity: SyncEntity, _ id: UUID) -> String { "\(entity.rawValue):\(id.uuidString.lowercased())" }

    static func index(transactionId: UUID, workspaceId: UUID, in db: Database, legacy: Bool = false) throws {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT entity, entityId, action, payloadJSON FROM sync_operations WHERE transactionId = ?",
            arguments: [transactionId]
        )
        let keys = try resourceKeys(rows, workspaceId: workspaceId, in: db, legacy: legacy)
        let sequence = try Int64.fetchOne(db, sql: "SELECT sequence FROM sync_transactions WHERE id = ?", arguments: [transactionId])!
        for (resource, exclusive) in keys {
            try db.execute(
                sql: "INSERT OR REPLACE INTO sync_dependency_keys(transactionId, resource, exclusive) VALUES (?, ?, ?)",
                arguments: [transactionId, resource, exclusive]
            )
            // Probe the resource index instead of scanning the Workspace's entire backlog per operation.
            let initialParent = try exclusive && Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sync_initial_entities WHERE resource = ? AND built = 0)",
                arguments: [resource]
            ) == true
            let mode = exclusive ? "" : "AND k.exclusive = 1"
            let edge = initialParent ? "prior.id, ?" : "?, prior.id"
            try db.execute(sql: """
            INSERT OR IGNORE INTO sync_dependencies(transactionId, predecessorId)
            SELECT \(edge) FROM sync_dependency_keys k JOIN sync_transactions prior ON prior.id = k.transactionId
            WHERE k.resource = ? \(mode) AND prior.workspace_id = ? AND prior.sequence < ?
            """, arguments: [transactionId, resource, workspaceId, sequence])
        }
        // Include unknown predecessors as barriers. No mutable payload or idempotency ID is rewritten.
        try db.execute(sql: """
        INSERT OR IGNORE INTO sync_dependencies(transactionId, predecessorId, provisional)
        SELECT ?, id, 1 FROM sync_transactions WHERE workspace_id = ? AND sequence < ? AND dependenciesReady = 0
        """, arguments: [transactionId, workspaceId, sequence])
        try db.execute(sql: "UPDATE sync_transactions SET dependenciesReady = 1 WHERE id = ?", arguments: [transactionId])
        // Indexing an old request replaces its provisional Workspace-wide edges with
        // actual resource conflicts. Unrelated later edits must not retain a false barrier.
        try db.execute(sql: """
        DELETE FROM sync_dependencies WHERE predecessorId = ? AND provisional = 1
          AND NOT EXISTS (
            SELECT 1 FROM sync_dependency_keys prior JOIN sync_dependency_keys later ON later.resource = prior.resource
            WHERE prior.transactionId = sync_dependencies.predecessorId
              AND later.transactionId = sync_dependencies.transactionId AND (prior.exclusive = 1 OR later.exclusive = 1))
        """, arguments: [transactionId])
        try db.execute(sql: "UPDATE sync_dependencies SET provisional = 0 WHERE predecessorId = ?", arguments: [transactionId])
        if !legacy {
            for row in rows {
                try db.execute(
                    sql: "DELETE FROM sync_relation_history WHERE entity = ? AND entityId = ?",
                    arguments: [row["entity"] as String, row["entityId"] as UUID]
                )
            }
        }
    }

    private static func resourceKeys(_ rows: [Row], workspaceId: UUID, in db: Database, legacy: Bool) throws -> [String: Bool] {
        let workspaceKey = "workspace:\(workspaceId.uuidString.lowercased())"
        var keys = [workspaceKey: false]
        func add(_ resource: String, exclusive: Bool = false) { keys[resource] = (keys[resource] ?? false) || exclusive }
        func reference(_ entity: SyncEntity, _ id: UUID, exclusive: Bool = false) { add("exists:\(key(entity, id))", exclusive: exclusive) }
        func project(_ id: UUID) throws {
            reference(.project, id)
            if let parent = try ProjectRecord.fetchOne(db, key: id)?.parentProjectId { reference(.project, parent) }
            for parent in try UUID.fetchAll(db, sql: """
            SELECT projectId FROM sync_relation_history WHERE entity = 'project' AND entityId = ? AND projectId IS NOT NULL
            UNION SELECT projectId FROM sync_confirmed_relations WHERE entity = 'project' AND entityId = ? AND projectId IS NOT NULL
            """, arguments: [id, id]) {
                reference(.project, parent)
            }
        }
        func meeting(_ id: UUID) throws {
            reference(.meeting, id)
            if let parent = try MeetingRecord.fetchOne(db, key: id)?.projectId { try project(parent) }
            for parent in try UUID.fetchAll(db, sql: """
            SELECT projectId FROM sync_relation_history WHERE entity = 'meeting' AND entityId = ? AND projectId IS NOT NULL
            UNION SELECT projectId FROM sync_confirmed_relations WHERE entity = 'meeting' AND entityId = ? AND projectId IS NOT NULL
            """, arguments: [id, id]) {
                try project(parent)
            }
        }
        for row in rows {
            let entity: SyncEntity = row["entity"], id: UUID = row["entityId"], action: SyncAction = row["action"]
            add("entity:\(key(entity, id))", exclusive: true)
            let payload: String? = row["payloadJSON"]
            let value = try payload.map { try SyncJSON.decoder.decode(Relations.self, from: Data($0.utf8)) }
            let history = try Row.fetchAll(db, sql: """
            SELECT workspaceId, projectId, meetingId, fileId FROM sync_relation_history WHERE entity = ? AND entityId = ?
            UNION SELECT workspaceId, projectId, meetingId, fileId FROM sync_confirmed_relations WHERE entity = ? AND entityId = ?
            """, arguments: [entity, id, entity, id])
            var projects = Set(history.compactMap { $0["projectId"] as UUID? })
            var meetings = Set(history.compactMap { $0["meetingId"] as UUID? })
            var files = Set(history.compactMap { $0["fileId"] as UUID? })
            if history.contains(where: { $0["workspaceId"] as UUID != workspaceId }) { add(workspaceKey, exclusive: true) }
            var structural = [.create, .delete, .reset].contains(action)
            switch entity {
            case .workspace: add(workspaceKey, exclusive: true)
            case .project:
                try projects.formUnion([value?.parentProjectId, ProjectRecord.fetchOne(db, key: id)?.parentProjectId].compactMap(\.self))
                structural = structural || history.contains { ($0["projectId"] as UUID?) != value?.parentProjectId }
                if action == .update, legacy || history.isEmpty { add(workspaceKey, exclusive: true) }
            case .meeting:
                try projects.formUnion([value?.projectId, MeetingRecord.fetchOne(db, key: id)?.projectId].compactMap(\.self))
                structural = structural || history.contains { ($0["projectId"] as UUID?) != value?.projectId }
                if action == .update, legacy || history.isEmpty { add(workspaceKey, exclusive: true) }
            case .summary, .transcript: meetings.insert(id)
            case .meetingAttachment:
                let current = try MeetingAttachmentRecord.fetchOne(db, key: id)
                meetings.formUnion([current?.meetingId, value?.meetingId].compactMap(\.self))
                files.formUnion([current?.fileId, value?.fileId].compactMap(\.self))
                if meetings.isEmpty || files.isEmpty || (legacy && action != .create) { add(workspaceKey, exclusive: true) }
            case .recording:
                try meetings.formUnion([value?.meetingId, RecordingSessionRecord.fetchOne(db, key: id)?.meetingId].compactMap(\.self))
                if meetings.isEmpty { add(workspaceKey, exclusive: true) }
            case .meetingEvent:
                meetings.formUnion([value?.meetingId].compactMap(\.self))
                if meetings.isEmpty { add(workspaceKey, exclusive: true) }
            case .file:
                structural = true
                try meetings.formUnion(UUID.fetchAll(db, sql: "SELECT meetingId FROM meeting_attachments WHERE fileId = ?", arguments: [id]))
            }
            reference(entity, id, exclusive: structural)
            for id in projects {
                try project(id)
            }
            for id in meetings {
                try meeting(id)
            }
            for id in files {
                reference(.file, id)
            }
        }
        return keys
    }

    static func backfill(in db: Database, limit: Int = 32) throws -> Int {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, workspace_id FROM sync_transactions WHERE dependenciesReady = 0 ORDER BY sequence LIMIT ?",
            arguments: [limit]
        )
        for row in rows {
            try index(transactionId: row["id"], workspaceId: row["workspace_id"], in: db, legacy: true)
        }
        return rows.count
    }

    static func confirmed(entity: SyncEntity, id: UUID, workspaceId: UUID, value: SyncCanonicalPayload, in db: Database) throws {
        try db.execute(sql: """
        INSERT INTO sync_confirmed_relations(workspaceId, entity, entityId, projectId, meetingId, fileId) VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(workspaceId, entity, entityId) DO UPDATE SET projectId = excluded.projectId, meetingId = excluded.meetingId, fileId = excluded.fileId
        """, arguments: [workspaceId, entity, id, entity == .project ? value.parentProjectId : value.projectId, value.meetingId, value.fileId])
    }

    /// Resolution may remove only this causal suffix. Unknown transactions conservatively depend on the whole prefix.
    static func affected(startingAt id: UUID, in db: Database) throws -> [UUID] {
        try UUID.fetchAll(db, sql: """
        WITH RECURSIVE affected(id) AS (
          SELECT ? UNION SELECT d.transactionId FROM sync_dependencies d JOIN affected a ON d.predecessorId = a.id
          UNION SELECT t.id FROM sync_transactions t JOIN sync_transactions p ON p.workspace_id = t.workspace_id AND p.sequence < t.sequence
            JOIN affected a ON a.id = p.id WHERE t.dependenciesReady = 0
        ) SELECT t.id FROM affected a JOIN sync_transactions t ON t.id = a.id ORDER BY t.sequence
        """, arguments: [id])
    }
}

extension SyncDependencies {
    static func meetingTransactions(meetingId: UUID, workspaceId: UUID, in db: Database) throws -> [UUID] {
        var resources = ["exists:\(key(.meeting, meetingId))"]
        if let project = try MeetingRecord.fetchOne(db, key: meetingId)?.projectId {
            resources.append("exists:\(key(.project, project))")
            if let parent = try ProjectRecord.fetchOne(db, key: project)?.parentProjectId { resources.append("exists:\(key(.project, parent))") }
        }
        let placeholders = resources.map { _ in "?" }.joined(separator: ",")
        return try UUID.fetchAll(
            db,
            sql: """
            WITH RECURSIVE required(id) AS (
              SELECT t.id FROM sync_transactions t WHERE t.workspace_id = ? AND (t.dependenciesReady = 0 OR EXISTS (
                SELECT 1 FROM sync_dependency_keys k WHERE k.transactionId = t.id
                  AND ((k.resource IN (\(placeholders)) AND (k.resource = ? OR k.exclusive = 1))
                    OR k.resource = ? AND k.exclusive = 1)))
              UNION SELECT d.predecessorId FROM sync_dependencies d JOIN required r ON r.id = d.transactionId
            ) SELECT id FROM required
            """,
            arguments: StatementArguments([workspaceId]) + StatementArguments(resources)
                + StatementArguments([resources[0], "workspace:\(workspaceId.uuidString.lowercased())"])
        )
    }

    static func meetingReady(meetingId: UUID, workspaceId: UUID, in db: Database) throws -> Bool {
        try parentConfirmed(meetingId: meetingId, workspaceId: workspaceId, in: db)
            && meetingTransactions(meetingId: meetingId, workspaceId: workspaceId, in: db).isEmpty
            && initialMeetingResources(meetingId: meetingId, workspaceId: workspaceId, in: db).isEmpty
    }

    static func parentConfirmed(meetingId: UUID, workspaceId: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM sync_entity_state s JOIN workspaces w ON w.id = s.workspace_id
          WHERE s.workspace_id = ? AND s.entity = 'meeting' AND s.entityId = ? AND s.confirmedRevision > 0
            AND w.accountConnectionId = w.syncConfirmedConnectionId AND w.syncRecoveryState IS NULL)
          AND NOT EXISTS (SELECT 1 FROM sync_transactions t JOIN sync_operations o ON o.transactionId = t.id
            WHERE t.workspace_id = ? AND (o.entity = 'workspace' AND o.action = 'reset'
              OR o.entity = 'meeting' AND o.entityId = ? AND o.action IN ('create', 'delete')))
        """, arguments: [workspaceId, meetingId, workspaceId, meetingId]) == true
    }

    private static func initialMeetingResources(meetingId: UUID, workspaceId: UUID, in db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
        SELECT resource FROM sync_initial_entities WHERE workspaceId = ? AND built = 0 AND (
          entity IN ('meeting', 'summary', 'transcript') AND entityId = ?
          OR entity = 'project' AND entityId IN (
            SELECT projectId FROM meetings WHERE id = ? UNION
            SELECT p.parentProjectId FROM projects p JOIN meetings m ON m.projectId = p.id WHERE m.id = ?)
          OR entity = 'meeting_attachment' AND entityId IN (SELECT id FROM meeting_attachments WHERE meetingId = ?)
          OR entity = 'file' AND entityId IN (SELECT fileId FROM meeting_attachments WHERE meetingId = ?))
        """, arguments: [workspaceId, meetingId, meetingId, meetingId, meetingId, meetingId])
    }

    static func prioritizeMeeting(meetingId: UUID, workspaceId: UUID, in db: Database) throws {
        for resource in try initialMeetingResources(meetingId: meetingId, workspaceId: workspaceId, in: db) {
            try db.execute(sql: "UPDATE sync_initial_entities SET priority = 1 WHERE resource = ? AND built = 0", arguments: [resource])
        }
        for id in try meetingTransactions(meetingId: meetingId, workspaceId: workspaceId, in: db) {
            try db.execute(sql: "UPDATE sync_transactions SET syncPriority = 1 WHERE id = ?", arguments: [id])
        }
    }
}
