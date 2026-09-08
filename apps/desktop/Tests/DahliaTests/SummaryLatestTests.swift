import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB
import Synchronization
@testable import Dahlia

#if canImport(Testing)
    import Testing

    extension TextContentTests {
        @Test(arguments: [false, true], ["none", "unrelated", "deferred"])
        func latestSummaryResynchronizesWhenRevisionChanges(beforeManifest: Bool, pending: String) async throws {
            let fixture = try textFixture()
            let document = try SummaryDocument(title: "Latest", sections: []).databaseJSONString()
            var digest = TextContentDigest()
            digest.add(document)
            let manifest: [String: Any] = [
                "version": 1, "entity": "summary", "entityId": fixture.meetingId.uuidString,
                "revision": 4, "present": true, "count": 1,
                "sha256": digest.digestHex(), "byteCount": digest.byteCount,
            ]
            var oldManifest = manifest
            oldManifest["revision"] = 3
            var body = manifest
            body["record"] = ["title": "Latest", "document": document, "createdAt": "2026-01-01T00:00:00.000Z"]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest)
            let oldManifestData = try JSONSerialization.data(withJSONObject: oldManifest)
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            let otherMeetingId = UUID.v7()
            try await fixture.queue.write { db in
                try db.execute(sql: "UPDATE vaults SET syncPullCursor = 'before' WHERE id = ?", arguments: [fixture.vaultId])
                if pending != "none" {
                    try MeetingRecord(id: otherMeetingId, vaultId: fixture.vaultId, projectId: nil, name: "Recording", createdAt: .now, updatedAt: .now).insert(db)
                    let transactionId = UUID.v7()
                    try db.execute(sql: """
                    INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt)
                    SELECT ?, id, accountConnectionId, ?, ? FROM vaults WHERE id = ?
                    """, arguments: [transactionId, Date(), Date(), fixture.vaultId])
                    try db.execute(sql: """
                    INSERT INTO sync_operations(transactionId, position, id, entity, action, entityId, payloadJSON)
                    VALUES (?, 0, ?, 'transcript', 'patch', ?, '{}')
                    """, arguments: [transactionId, UUID.v7(), otherMeetingId])
                }
                try db.execute(sql: "INSERT INTO summaries(meetingId, title, createdAt) VALUES (?, 'Old', ?)", arguments: [fixture.meetingId, Date()])
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'summary', ?, 3)", arguments: [fixture.vaultId, fixture.meetingId])
                try db.execute(
                    sql: "INSERT INTO sync_content_state(vaultId, entity, entityId) VALUES (?, 'summary', ?)",
                    arguments: [fixture.vaultId, fixture.meetingId]
                )
            }
            var changes: [[String: Any]] = []
            if pending == "deferred" {
                changes.append([
                    "sequence": 3, "entity": "transcript", "entityId": otherMeetingId.uuidString,
                    "action": "upsert", "revision": 2,
                    "record": ["contentOmitted": true, "contentPresent": true, "contentCount": 1],
                ])
            }
            changes.append([
                "sequence": 4, "entity": "summary", "entityId": fixture.meetingId.uuidString,
                "action": "upsert", "revision": 4,
                "record": ["title": "Latest", "createdAt": "2026-01-01T00:00:00.000Z", "contentOmitted": true, "contentPresent": true, "contentCount": 1],
            ])
            let changeData = try JSONSerialization.data(withJSONObject: [
                "items": changes, "cursor": "after", "highWaterCursor": "after", "hasMore": false,
            ])
            let calls = Mutex(0)
            let syncs = Mutex(0)
            let provider = provider(fixture) { request in
                if request.url!.path.hasSuffix("/capabilities") { return (200, [:], Data(#"{"sync":{"version":3}}"#.utf8)) }
                if request.url!.path.hasSuffix("/changes") {
                    syncs.withLock { $0 += 1 }
                    return (200, [:], changeData)
                }
                #expect(request.url?
                    .path ==
                    "/api/v1/vaults/\(fixture.vaultId.uuidString.lowercased())/meetings/\(fixture.meetingId.uuidString.lowercased())/summary/latest")
                #expect(!(request.url!.query ?? "").contains("revision"))
                let call = calls.withLock { $0 += 1
                    return $0
                }
                let isManifest = (request.url!.query ?? "").contains("manifest")
                return (200, [:], isManifest ? (call == 1 && !beforeManifest ? oldManifestData : manifestData) : bodyData)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await provider.ensure(entity: .summary, id: fixture.meetingId, dbQueue: fixture.queue)
            #expect(syncs.withLock { $0 } == 1)
            #expect(try await fixture.queue.read { try TextContentAccess.summary(meetingId: fixture.meetingId, in: $0)?.document } == document)
            #expect(try await fixture.queue
                .read { try TextContentAccess.availability(entity: .summary, id: fixture.meetingId, in: $0).revision } == 4)
            try await fixture.queue.read { db throws in
                #expect(try SyncTransactionQueue.hasPending(vaultId: fixture.vaultId, in: db) == (pending != "none"))
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM vaults WHERE id = ?", arguments: [fixture.vaultId]) == (pending == "deferred" ? "before" : "after"))
            }
        }

    }
#endif
