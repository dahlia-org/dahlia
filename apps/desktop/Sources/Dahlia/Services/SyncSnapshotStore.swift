import Foundation
import GRDB

struct SyncSnapshotPage: Decodable {
    struct Record: Decodable {
        let entity: SyncEntity
        let id: UUID
        let revision: Int?
        let record: SyncCanonicalPayload?
    }

    let items: [Record]
    let startCursor: String
    let nextCursor: String?
}

/// Rebuildable recovery data. Canonical content is never accumulated for an entire Workspace in memory.
final class SyncSnapshotStore: Sendable {
    private let directory: URL
    private let database: DatabaseQueue

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dahlia-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        database = try DatabaseQueue(path: directory.appendingPathComponent("snapshot.sqlite").path)
        try database.write { db in
            try db.execute(sql: """
            CREATE TABLE changes (
                entity TEXT NOT NULL, entityId TEXT NOT NULL, phase INTEGER NOT NULL,
                meetingId TEXT, revision INTEGER, payload BLOB NOT NULL,
                PRIMARY KEY (entity, entityId)
            ) WITHOUT ROWID;
            CREATE INDEX changes_page ON changes(phase, entityId);
            """)
        }
    }

    deinit {
        try? database.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func merge(_ changes: [SyncChangePage.Change]) async throws {
        try await database.write { db in
            for change in changes {
                if change.entity == .workspace, change.action == "reset" {
                    try db.execute(sql: "DELETE FROM changes")
                    guard change.record != nil else { continue }
                }
                if change.action == "delete" || change.record == nil {
                    try db.execute(
                        sql: "DELETE FROM changes WHERE entity = ? AND entityId = ?",
                        arguments: [change.entity, change.entityId.uuidString]
                    )
                    if change.entity == .meeting {
                        try db.execute(
                            sql: "DELETE FROM changes WHERE meetingId = ? OR (entity IN ('summary', 'transcript') AND entityId = ?)",
                            arguments: [change.entityId.uuidString, change.entityId.uuidString]
                        )
                    }
                    continue
                }
                let upsert = SyncChangePage.Change(
                    sequence: change.sequence, entity: change.entity, entityId: change.entityId,
                    action: "upsert", revision: change.revision, record: change.record
                )
                try db.execute(
                    sql: """
                    INSERT INTO changes(entity, entityId, phase, meetingId, revision, payload) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(entity, entityId) DO UPDATE SET
                        phase = excluded.phase, meetingId = excluded.meetingId,
                        revision = excluded.revision, payload = excluded.payload
                    """,
                    arguments: [
                        change.entity, change.entityId.uuidString, Self.phase(upsert),
                        change.record?.meetingId?.uuidString, change.revision, SyncJSON.encoder.encode(upsert),
                    ]
                )
            }
        }
    }

    /// The caller owns the destination transaction; this temporary store is immutable after staging.
    func forEachChange(_ body: (SyncChangePage.Change) throws -> Void) throws {
        try database.read { db in
            let cursor = try Data.fetchCursor(db, sql: "SELECT payload FROM changes ORDER BY phase, entityId")
            while let payload = try cursor.next() {
                try body(SyncJSON.decoder.decode(SyncChangePage.Change.self, from: payload))
            }
        }
    }

    /// Restoring a locally deleted parent also restores its canonical children and referenced files.
    func reconciliationSubtree(_ roots: Set<SyncReconciliation.Key>) throws -> Set<SyncReconciliation.Key> {
        guard !roots.isEmpty else { return [] }
        var keys = roots
        try forEachChange { change in
            guard let record = change.record else { return }
            let key = SyncReconciliation.Key(entity: change.entity, id: change.entityId)
            let parents = [
                record.parentProjectId.map { SyncReconciliation.Key(entity: .project, id: $0) },
                record.projectId.map { SyncReconciliation.Key(entity: .project, id: $0) },
                record.meetingId.map { SyncReconciliation.Key(entity: .meeting, id: $0) },
                record.fileId.map { SyncReconciliation.Key(entity: .file, id: $0) },
                [.summary, .transcript].contains(change.entity) ? SyncReconciliation.Key(entity: .meeting, id: change.entityId) : nil,
            ].compactMap(\.self)
            if keys.contains(key) || parents.contains(where: { $0.entity == .file ? roots.contains($0) : keys.contains($0) }) {
                keys.insert(key)
                if let file = record.fileId { keys.insert(.init(entity: .file, id: file)) }
            }
        }
        return keys
    }

    func page(after: SyncChangePage.Change? = nil) async throws -> [SyncChangePage.Change] {
        try await database.read { db in
            let phase = after.map(Self.phase) ?? -1
            return try Data.fetchAll(
                db,
                sql: "SELECT payload FROM changes WHERE phase > ? OR (phase = ? AND entityId > ?) ORDER BY phase, entityId LIMIT 100",
                arguments: [phase, phase, after?.entityId.uuidString ?? ""]
            ).map { try SyncJSON.decoder.decode(SyncChangePage.Change.self, from: $0) }
        }
    }

    func projects() async throws -> [SyncProjectSnapshot] {
        try await database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM changes WHERE entity = 'project' ORDER BY phase, entityId")
                .map { data in
                    let change = try SyncJSON.decoder.decode(SyncChangePage.Change.self, from: data)
                    guard let record = change.record, let name = record.name, let revision = change.revision,
                          let createdAt = record.createdAt else { throw SyncTransactionQueueError.invalidReceipt }
                    return SyncProjectSnapshot(
                        icon: record.icon, color: record.color,
                        projectId: change.entityId, parentProjectId: record.parentProjectId, name: name,
                        description: record.description ?? "", projectType: record.projectType,
                        revision: revision, createdAt: createdAt
                    )
                }
        }
    }

    func revisionChanges() async throws -> [SyncChangePage.Change] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT entity, entityId, revision, CASE WHEN entity = 'workspace' THEN payload END AS payload FROM changes")
                .map { row in
                    if let payload: Data = row["payload"] {
                        return try SyncJSON.decoder.decode(SyncChangePage.Change.self, from: payload)
                    }
                    guard let entity = SyncEntity(rawValue: row["entity"]), let id = UUID(uuidString: row["entityId"]) else {
                        throw SyncTransactionQueueError.invalidReceipt
                    }
                    return SyncChangePage.Change(sequence: 0, entity: entity, entityId: id, action: "upsert", revision: row["revision"], record: nil)
                }
        }
    }

    func resetSnapshot() async throws -> SyncResetSnapshot {
        try await database.read { db in
            var ids: [SyncEntity: Set<UUID>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT entity, entityId FROM changes") {
                guard let entity = SyncEntity(rawValue: row["entity"]), let id = UUID(uuidString: row["entityId"]) else {
                    throw SyncTransactionQueueError.invalidReceipt
                }
                ids[entity, default: []].insert(id)
            }
            return SyncResetSnapshot(ids: ids)
        }
    }

    private static func phase(_ change: SyncChangePage.Change) -> Int {
        switch change.entity {
        case .workspace: 0
        case .project: change.record?.parentProjectId == nil ? 1 : 2
        case .meeting: 3
        case .summary: 4
        case .transcript: 5
        case .file: 6
        case .meetingAttachment: 7
        case .meetingEvent: 8
        case .recording: 9
        }
    }
}
