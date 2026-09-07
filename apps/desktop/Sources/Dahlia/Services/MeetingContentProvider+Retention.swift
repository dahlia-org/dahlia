import DahliaRuntimeSupport
import Foundation
import GRDB

extension MeetingContentProvider {
    func scheduleMaintenance(dbQueue: DatabaseQueue) {
        let key = ObjectIdentifier(dbQueue)
        guard maintenance[key] == nil else { return }
        maintenance[key] = Task(priority: .utility) {
            defer { maintenance[key] = nil }
            do {
                let verify = try await dbQueue.read { db in
                    try Row.fetchAll(db, sql: """
                    SELECT c.entity, c.entityId FROM sync_content_state c
                    JOIN sync_entity_state s ON s.vaultId = c.vaultId AND s.entity = c.entity AND s.entityId = c.entityId
                    WHERE c.complete = 1 AND c.fetchError IS NOT 'integrityFailure' AND (c.verifiedHash IS NULL OR c.residentRevision IS NOT s.confirmedRevision)
                    ORDER BY c.fetchError IS NOT NULL, c.lastAccessedAt LIMIT 20
                    """).map { ($0["entity"] as String, $0["entityId"] as UUID) }
                }
                for (raw, id) in verify {
                    try Task.checkCancellation()
                    if let entity = TextContentEntity(rawValue: raw) {
                        try? await ensure(entity: entity, id: id, dbQueue: dbQueue, refresh: true, prefetchBudget: Int.max)
                    }
                }
                try await trim(dbQueue: dbQueue)
                let recent = try await dbQueue.read { db in
                    try UUID.fetchAll(db, sql: """
                    SELECT m.id FROM meetings m JOIN vaults v ON v.id = m.vaultId
                    WHERE v.accountConnectionId IS NOT NULL AND v.syncRecoveryState IS NULL AND v.syncPullCursor IS NOT NULL
                    ORDER BY coalesce(m.recordingStartedAt, m.createdAt) DESC, m.id DESC LIMIT 20
                    """)
                }
                for meetingId in recent {
                    let content = try await dbQueue.read { db in
                        try Row.fetchAll(db, sql: """
                        SELECT entity, entityId FROM sync_content_state WHERE complete = 0 AND lastAccessedAt IS NULL
                        AND (entityId = ? AND entity IN ('summary', 'transcript')
                          OR entity = 'file' AND entityId IN (SELECT fileId FROM meeting_files WHERE meetingId = ?))
                        """, arguments: [meetingId, meetingId]).map { ($0["entity"] as String, $0["entityId"] as UUID) }
                    }
                    for (raw, id) in content {
                        let budget = try await Self.capacityBytes * 4 / 5 - (Self.usedBytes(dbQueue: dbQueue))
                        guard budget > 0 else { return }
                        guard let entity = TextContentEntity(rawValue: raw) else { continue }
                        try? await ensure(entity: entity, id: id, dbQueue: dbQueue, refresh: true, prefetchBudget: budget)
                    }
                }
                try await ScreenshotStorageMaintenance.reclaimIncrementally(dbQueue: dbQueue)
            } catch { /* Maintenance is retried after the next synchronization; durable work is unaffected. */ }
        }
    }

    static func usedBytes(dbQueue: DatabaseQueue) async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: """
            SELECT coalesce(sum(c.byteCount), 0) FROM sync_content_state c JOIN vaults v ON v.id = c.vaultId
            WHERE v.accountConnectionId IS NOT NULL
            """) ?? 0
        }
    }

    func trim(dbQueue: DatabaseQueue, capacity: Int = MeetingContentProvider.capacityBytes) async throws {
        var used = try await Self.usedBytes(dbQueue: dbQueue)
        guard used > capacity else { return }
        let candidates = try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT entity, entityId FROM sync_content_state WHERE complete = 1 AND byteCount > 0 AND verifiedHash IS NOT NULL ORDER BY lastAccessedAt, entityId"
            )
            .map { ($0["entity"] as String, $0["entityId"] as UUID) }
        }
        for (raw, id) in candidates {
            guard used > capacity * 4 / 5 else { break }
            try Task.checkCancellation()
            guard let entity = TextContentEntity(rawValue: raw) else { continue }
            let key = Key(database: ObjectIdentifier(dbQueue), entity: entity, id: id)
            guard leases[key] == nil, requests[key] == nil else { continue }
            used -= try evict(entity: entity, id: id, dbQueue: dbQueue)
        }
    }

    private func evict(entity: TextContentEntity, id: UUID, dbQueue: DatabaseQueue) throws -> Int {
        let raw = entity.rawValue
        let protected = Set(retainedVaults[ObjectIdentifier(dbQueue), default: [:]].keys)
        // Keep lease acquisition and the eviction transaction ordered on this actor.
        return try dbQueue.write { db in
            guard let source = try TextContentStore.source(entity: entity, id: id, in: db), !protected.contains(source.vaultId),
                  try TextContentStore.mayReplace(source, entity: entity, id: id, in: db),
                  let row = try Row.fetchOne(
                      db,
                      sql: "SELECT residentRevision, verifiedHash FROM sync_content_state WHERE entity = ? AND entityId = ?",
                      arguments: [raw, id]
                  ),
                  row["residentRevision"] as Int? == source.revision,
                  let fingerprint = try TextContentStore.fingerprint(entity: entity, id: id, in: db),
                  fingerprint.hash == row["verifiedHash"] as String? else { return 0 }
            try TextContentStore.releaseBody(entity: entity, id: id, in: db)
            return fingerprint.bytes
        }
    }
}
