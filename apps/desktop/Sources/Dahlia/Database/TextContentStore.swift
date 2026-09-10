import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

enum TextContentStore {
    struct Source: Equatable, Sendable {
        let vaultId: UUID
        let connectionId: UUID
        let origin: String
        let generation: Int64
        let revision: Int
        let checksum: String?

        var context: RemoteChangePolicy.Context {
            .init(vaultId: vaultId, connectionId: connectionId, generation: generation)
        }
    }

    static func source(entity: TextContentEntity, id: UUID, in db: Database) throws -> Source? {
        let parent = entity == .file ? "files" : "meetings"
        guard let row = try Row.fetchOne(db, sql: """
        SELECT v.id, v.accountConnectionId, c.origin, v.syncMutationGeneration, s.confirmedRevision, \(entity == .file ? "p.checksum" :
            "NULL") AS checksum
        FROM \(parent) p JOIN vaults v ON v.id = p.vaultId
        JOIN dahlia_account_connections c ON c.id = v.accountConnectionId
        LEFT JOIN sync_entity_state s ON s.vaultId = v.id AND s.entity = ? AND s.entityId = p.id
        WHERE p.id = ? AND v.accountConnectionId = v.syncConfirmedConnectionId
        """, arguments: [entity.rawValue, id]) else { return nil }
        return Source(
            vaultId: row["id"],
            connectionId: row["accountConnectionId"],
            origin: row["origin"],
            generation: row["syncMutationGeneration"],
            revision: row["confirmedRevision"] ?? 0,
            checksum: row["checksum"]
        )
    }

    static func mayReplace(_ expected: Source, entity: TextContentEntity, id: UUID, in db: Database) throws -> Bool {
        guard try source(entity: entity, id: id, in: db) == expected,
              try !SyncTransactionQueue.hasPending(vaultId: expected.vaultId, in: db),
              try String.fetchOne(db, sql: "SELECT syncRecoveryState FROM vaults WHERE id = ?", arguments: [expected.vaultId]) == nil,
              try !RecordingSessionRecord.hasActiveRecording(vaultId: expected.vaultId, in: db)
        else { return false }
        return true
    }

    /// Fetching uses the sync policy; eviction retains the stricter mayReplace policy.
    static func mayFetch(_ expected: Source, entity: TextContentEntity, id: UUID, in db: Database) throws -> Bool {
        guard try source(entity: entity, id: id, in: db) == expected else { return false }
        guard expected.revision > 0 else { return try mayReplace(expected, entity: entity, id: id, in: db) }
        guard let syncEntity = SyncEntity(rawValue: entity.rawValue) else { return false }
        return try RemoteChangePolicy.permits(syncEntity, id: id, vaultId: expected.vaultId, in: db)
    }

    static func registerLocal(entity: TextContentEntity, id: UUID, vaultId: UUID, in db: Database) throws {
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sync_content_state WHERE vaultId = ? AND entity = ? AND entityId = ?)",
            arguments: [vaultId, entity.rawValue, id]
        ) != true else { return }
        let byteCountSQL = switch entity {
        case .summary: "SELECT length(CAST(document AS BLOB)) FROM summary_bodies WHERE meetingId = ?"
        case .transcript: "SELECT sum(length(CAST(b.text AS BLOB))) FROM transcript_segments t JOIN transcript_segment_bodies b ON b.segmentId = t.id WHERE t.meetingId = ?"
        case .file:
            """
            SELECT coalesce(length(CAST(ocrText AS BLOB)), 0)
                 + coalesce(length(CAST(caption AS BLOB)), 0)
            FROM file_text_bodies WHERE fileId = ?
            """
        }
        let bytes = try Int.fetchOne(db, sql: byteCountSQL, arguments: [id]) ?? 0
        try db.execute(sql: """
        INSERT INTO sync_content_state(vaultId, entity, entityId, residentRevision, complete, byteCount)
        VALUES (?, ?, ?, (SELECT confirmedRevision FROM sync_entity_state WHERE vaultId = ? AND entity = ? AND entityId = ?), 1, ?)
        """, arguments: [vaultId, entity.rawValue, id, vaultId, entity.rawValue, id, bytes])
    }

    static func requireVaultComplete(vaultId: UUID, in db: Database) throws {
        guard try !SyncTransactionQueue.hasPending(vaultId: vaultId, in: db),
              try !RecordingSessionRecord.hasActiveRecording(vaultId: vaultId, in: db),
              try String.fetchOne(db, sql: "SELECT syncRecoveryState FROM vaults WHERE id = ?", arguments: [vaultId]) == nil,
              try Bool.fetchOne(db, sql: """
              SELECT EXISTS(SELECT 1 FROM sync_content_state c LEFT JOIN sync_entity_state s
                ON s.vaultId = c.vaultId AND s.entity = c.entity AND s.entityId = c.entityId
                WHERE c.vaultId = ? AND (c.complete = 0 OR s.confirmedRevision IS NOT NULL AND c.residentRevision IS NOT s.confirmedRevision))
              """, arguments: [vaultId]) != true else { throw TextContentError.incomplete }
        let meetings = try UUID.fetchCursor(db, sql: "SELECT id FROM meetings WHERE vaultId = ?", arguments: [vaultId])
        while let id = try meetings.next() {
            try TextContentAccess.requireComplete(entity: .summary, id: id, in: db)
            try TextContentAccess.requireComplete(entity: .transcript, id: id, in: db)
        }
        let files = try UUID.fetchCursor(db, sql: "SELECT id FROM files WHERE vaultId = ?", arguments: [vaultId])
        while let id = try files.next() {
            try TextContentAccess.requireComplete(entity: .file, id: id, in: db)
        }
    }

    /// Metadata observation preserves the old body and its own revision, even when the remote revision advances.
    static func observe(entity: SyncEntity, id: UUID, vaultId: UUID, value: SyncCanonicalPayload, in db: Database) throws -> Bool {
        guard value.contentOmitted == true, let contentEntity = TextContentEntity(rawValue: entity.rawValue) else { return false }
        let present = value.contentPresent ?? true
        try db.execute(sql: """
        INSERT INTO sync_content_state(vaultId, entity, entityId, present, contentCount)
        VALUES (?, ?, ?, ?, ?) ON CONFLICT(vaultId, entity, entityId) DO UPDATE SET
            present = excluded.present, contentCount = excluded.contentCount, fetchError = NULL
        """, arguments: [vaultId, entity, id, present, value.contentCount])
        if contentEntity == .summary {
            if present {
                guard let title = value.title, let date = value.createdAt else { throw TextContentError.integrityFailure }
                try db.execute(sql: """
                INSERT INTO summaries(meetingId, title, createdAt) VALUES (?, ?, ?)
                ON CONFLICT(meetingId) DO UPDATE SET title = excluded.title, createdAt = excluded.createdAt
                """, arguments: [id, title, date])
            } else {
                try db.execute(sql: "DELETE FROM summaries WHERE meetingId = ?", arguments: [id])
                try db.execute(
                    sql: "UPDATE sync_content_state SET complete = 1, byteCount = 0, verifiedHash = NULL WHERE entity = 'summary' AND entityId = ?",
                    arguments: [id]
                )
            }
        } else if contentEntity == .transcript {
            if let info = value.transcript {
                let resident = try Row.fetchOne(db, sql: """
                SELECT complete, residentRevision FROM sync_content_state WHERE entity = 'transcript' AND entityId = ?
                """, arguments: [id])
                // A stale body remains readable and editable with its own generation until hydration publishes both.
                if resident?["complete"] as Bool? != true || resident?["residentRevision"] as Int? == info.syncRevision {
                    try TranscriptRecord.applyCanonical(meetingId: id, info: info, in: db)
                }
            }
        } else if contentEntity == .file {
            try FileRecord.applyCanonical(id: id, vaultId: vaultId, value: value, in: db)
        }
        return true
    }

    static func fingerprint(entity: TextContentEntity, id: UUID, in db: Database) throws -> (hash: String, bytes: Int, count: Int)? {
        guard (try? TextContentAccess.requireComplete(entity: entity, id: id, in: db)) != nil else { return nil }
        var digest = TextContentDigest()
        var count = 0
        switch entity {
        case .transcript:
            let rows = try Row.fetchCursor(
                db,
                sql: """
                SELECT t.id, b.text
                FROM transcript_segments t JOIN transcript_segment_bodies b ON b.segmentId = t.id
                WHERE t.meetingId = ? ORDER BY t.startedAt, t.id
                """,
                arguments: [id]
            )
            while let row = try rows.next() {
                guard let text: String = row["text"] else { return nil }
                digest.add((row["id"] as UUID).uuidString.lowercased(), body: false)
                digest.add(text)
                count += 1
            }
        case .summary:
            let value = try String.fetchOne(db, sql: "SELECT document FROM summary_bodies WHERE meetingId = ?", arguments: [id])
            digest.add(value)
            count = value == nil ? 0 : 1
        case .file:
            guard let text = try TextContentAccess.fileText(fileId: id, in: db) else { return nil }
            digest.add(text.ocrText)
            digest.add(text.caption)
            count = 2
        }
        return (digest.digestHex(), digest.byteCount, count)
    }

    /// Both verified eviction and explicit Server adoption use the same absent-body and search representation.
    static func releaseBody(entity: TextContentEntity, id: UUID, in db: Database) throws {
        let raw = entity.rawValue
        switch entity {
        case .transcript:
            try db.execute(
                sql: "DELETE FROM transcript_segment_bodies WHERE segmentId IN (SELECT id FROM transcript_segments WHERE meetingId = ?)",
                arguments: [id]
            )
        case .summary:
            try db.execute(sql: "DELETE FROM summary_bodies WHERE meetingId = ?", arguments: [id])
        case .file:
            try db.execute(sql: "DELETE FROM file_text_bodies WHERE fileId = ?", arguments: [id])
        }
        try db.execute(
            sql: """
            UPDATE sync_content_state SET complete = 0, byteCount = 0, verifiedHash = NULL, fetchError = NULL,
                lastAccessedAt = coalesce(lastAccessedAt, ?) WHERE entity = ? AND entityId = ?
            """,
            arguments: [Date(), raw, id]
        )
        let documents = entity == .transcript ? [] : try Int64.fetchAll(
            db,
            sql: entity == .file
                ? "SELECT id FROM search_documents WHERE kind = 'screenshot' AND sourceId IN (SELECT id FROM meeting_attachments WHERE fileId = ?)"
                : "SELECT id FROM search_documents WHERE kind = 'meeting' AND sourceId = ?",
            arguments: [id]
        )
        for document in documents {
            try db.execute(sql: "DELETE FROM search_documents_fts WHERE rowid = ?", arguments: [document])
            try db.execute(sql: "DELETE FROM search_documents WHERE id = ?", arguments: [document])
        }
        if entity == .summary {
            let generation = try Int.fetchOne(db, sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'fts'") ?? 1
            try indexMeetingDocument(id: id, generation: generation, in: db)
        }
    }

    static func markVerified(_ manifest: TextContentManifest, source: Source, accessed: Bool, in db: Database) throws {
        if manifest.entity == .transcript, let info = manifest.transcript {
            try TranscriptRecord.applyCanonical(meetingId: manifest.entityId, info: info, in: db)
        }
        try db.execute(sql: """
        INSERT INTO sync_content_state(vaultId, entity, entityId, residentRevision, complete, present, contentCount, verifiedHash, byteCount, lastAccessedAt)
        VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?)
        ON CONFLICT(vaultId, entity, entityId) DO UPDATE SET residentRevision = excluded.residentRevision,
            complete = 1, present = excluded.present, contentCount = excluded.contentCount,
            verifiedHash = excluded.verifiedHash, byteCount = excluded.byteCount, fetchError = NULL,
            lastAccessedAt = coalesce(excluded.lastAccessedAt, sync_content_state.lastAccessedAt)
        """, arguments: [
            source.vaultId,
            manifest.entity.rawValue,
            manifest.entityId,
            manifest.revision,
            manifest.present,
            manifest.count,
            manifest.sha256,
            manifest.byteCount,
            accessed ? Date() : nil,
        ])
    }
}
