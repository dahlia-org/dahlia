import Foundation
import GRDB

/// Durable ingress is independent of projection work and of the Workspace transaction queue.
actor DocumentPersistence {
    struct OrphanContext: Sendable {
        let workspaceID: UUID
        let meetingID: UUID
        let name: String
        var connectionID: UUID?
    }

    let dbQueue: DatabaseQueue
    private let core = DocumentCoreWorker()

    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }
    deinit { core.stop() }

    func prepare(meetingID: UUID) async throws -> DocumentCoreResult {
        let legacy = try await dbQueue.read { db -> MeetingNoteRecord? in
            guard try DocumentRecord.notes(in: db, meetingID: meetingID) == nil,
                  let meeting = try MeetingRecord.fetchOne(db, key: meetingID),
                  let workspace = try WorkspaceRecord.fetchOne(db, key: meeting.workspaceId),
                  workspace.accountConnectionId == nil else { return nil }
            return try MeetingNoteRecord.fetchOne(db, key: meetingID)
        }
        if let legacy {
            let converted = try await core.process(DocumentCoreCommand(text: legacy.text))
            try await dbQueue.write { db in
                guard try DocumentRecord.notes(in: db, meetingID: meetingID) == nil,
                      let meeting = try MeetingRecord.fetchOne(db, key: meetingID),
                      let workspace = try WorkspaceRecord.fetchOne(db, key: meeting.workspaceId),
                      workspace.accountConnectionId == nil else { return }
                try DocumentRecord(
                    id: .v7(),
                    workspaceId: meeting.workspaceId,
                    meetingId: meetingID,
                    checkpoint: converted.checkpoint,
                    text: converted.projection.text,
                    createdAt: legacy.createdAt,
                    updatedAt: legacy.updatedAt
                ).insert(db)
                try db.execute(sql: "INSERT OR IGNORE INTO document_legacy_imports VALUES (?, ?)", arguments: [meetingID, Date()])
            }
        }
        return try await materialize(meetingID: meetingID)
    }

    private enum AppendRetry: Error { case changed }

    /// Validate off MainActor, then atomically commit only against the validated causal snapshot.
    func append(
        meetingID: UUID,
        update: String,
        local: Bool,
        orphan: OrphanContext? = nil,
        privateOnly: Bool = false,
        restoreDraft: Bool = false,
        recovery: String? = nil
    ) async throws {
        guard update.utf8.count <= DocumentLimits.encodedUpdateBytes,
              let bytes = Data(base64Encoded: update), bytes.count <= DocumentLimits.stateBytes else { throw DocumentCoreError.invalidCommand }
        if let recovery {
            guard local, recovery.utf8.count <= DocumentLimits.stateBytes * 3 else { throw DocumentCoreError.invalidCommand }
            let blocks = try JSONDecoder().decode([DocumentBlock].self, from: Data(recovery.utf8))
            guard !blocks.isEmpty, blocks.count <= 50000,
                  blocks
                  .allSatisfy({
                      $0.id.utf16.count <= 128 && ["paragraph", "heading", "codeBlock"].contains($0.type) && $0.text.utf16.count <= 2_000_000 })
            else { throw DocumentCoreError.invalidCommand }
        }
        let commit = SyncDiagnostics.begin("DocumentLocalCommit")
        defer { SyncDiagnostics.end("DocumentLocalCommit", commit) }
        while true {
            let source = try await dbQueue.read { db -> (DocumentRecord?, [String], Int64, Bool) in
                let record = try DocumentRecord.notes(in: db, meetingID: meetingID)
                let updates = try DocumentUpdateRecord.filter(Column("documentId") == record?.id)
                    .filter(Column("id") > (record?.checkpointSequence ?? 0)).order(Column("id")).fetchAll(db)
                let latest = try Int64.fetchOne(db, sql: "SELECT max(id) FROM document_updates WHERE documentId = ?", arguments: [record?.id]) ?? 0
                var prerequisite = updates.map(\.payload)
                if restoreDraft, let orphan {
                    prerequisite += try String.fetchAll(db, sql: """
                    SELECT value FROM document_local_archives a, json_each(a.payload, '$.updates')
                    WHERE a.id = ? AND a.workspace_id = ? AND a.meetingId = ?
                    """, arguments: [meetingID, orphan.workspaceID, meetingID])
                }
                let meeting = try MeetingRecord.fetchOne(db, key: meetingID)
                let workspace = try meeting.flatMap { try WorkspaceRecord.fetchOne(db, key: $0.workspaceId) }
                let moved = orphan.map { $0.workspaceID != meeting?.workspaceId || $0.connectionID != workspace?.accountConnectionId } ?? false
                return (
                    record,
                    prerequisite,
                    latest,
                    !privateOnly && workspace != nil && (!local || (workspace?.allowsCanonicalEdits == true && !moved))
                )
            }
            if source.3 {
                _ = try await core.process(DocumentCoreCommand(checkpoint: source.0?.checkpoint, updates: source.1 + [update], local: local))
            }
            do {
                let privateCopy = try await dbQueue.write { db -> Bool in
                    let write = SyncDiagnostics.begin("DocumentDatabaseWrite")
                    defer { SyncDiagnostics.end("DocumentDatabaseWrite", write) }
                    guard !privateOnly, let meeting = try MeetingRecord.fetchOne(db, key: meetingID),
                          let workspace = try WorkspaceRecord.fetchOne(db, key: meeting.workspaceId) else {
                        guard local, let orphan, orphan.meetingID == meetingID,
                              try WorkspaceRecord.fetchOne(db, key: orphan.workspaceID) != nil else { throw DocumentCoreError.unavailable }
                        try db.execute(sql: """
                        INSERT INTO document_local_archives (id, workspace_id, meetingId, name, payload, createdAt)
                        VALUES (?, ?, ?, ?, json_object('checkpoint', NULL, 'updates', json_array(?), 'copies', json_array(), 'recoveries', json_array(), 'legacy', NULL), ?)
                        ON CONFLICT(id) DO UPDATE SET payload = json_insert(payload, '$.updates[#]', ?)
                        WHERE workspace_id = ? AND meetingId = ?
                        """, arguments: [
                            meetingID,
                            orphan.workspaceID,
                            meetingID,
                            orphan.name,
                            update,
                            Date(),
                            update,
                            orphan.workspaceID,
                            meetingID,
                        ])
                        guard db.changesCount > 0 else { throw DocumentCoreError.unavailable }
                        if let recovery {
                            try db.execute(
                                sql: "UPDATE document_local_archives SET payload = json_insert(payload, '$.recoveries[#]', json(?)) WHERE id = ?",
                                arguments: [recovery, meetingID]
                            )
                        }
                        return true
                    }
                    // An editor opened before a move must never publish its old private CRDT into the new account.
                    let moved = orphan.map { $0.workspaceID != meeting.workspaceId || $0.connectionID != workspace.accountConnectionId } ?? false
                    if local, !workspace.allowsCanonicalEdits || moved {
                        try DocumentRetention.archiveBeforeRemoteDeletion(
                            meetingID: meetingID,
                            rejectedUpdate: update,
                            rejectedRecovery: recovery,
                            in: db
                        )
                        return true
                    }
                    let existing = try DocumentRecord.notes(in: db, meetingID: meetingID)
                    let latest = try Int64
                        .fetchOne(db, sql: "SELECT max(id) FROM document_updates WHERE documentId = ?", arguments: [existing?.id]) ?? 0
                    guard source.3, existing?.id == source.0?.id, existing?.checkpointSequence == source.0?.checkpointSequence,
                          existing?.checkpoint == source.0?.checkpoint,
                          existing?.generation == source.0?.generation, latest == source.2 else { throw AppendRetry.changed }
                    if let existing, !existing.resident { throw DocumentCoreError.unavailable }
                    let now = Date()
                    if try DocumentRecord.notes(in: db, meetingID: meetingID) == nil {
                        try DocumentRecord(
                            id: .v7(),
                            workspaceId: meeting.workspaceId,
                            meetingId: meetingID,
                            checkpoint: "AAA=",
                            createdAt: now,
                            updatedAt: now
                        ).insert(db)
                    }
                    guard let document = try DocumentRecord.notes(in: db, meetingID: meetingID) else { throw DocumentCoreError.unavailable }
                    if local, restoreDraft, let orphan, orphan.meetingID == meetingID {
                        // A resolved draft's next delta can reference structs already saved in its private archive.
                        // Replay those prerequisites only after the original account/Workspace checks above.
                        try db.execute(sql: """
                        INSERT INTO document_updates(documentId, payload, pending, createdAt)
                        SELECT ?, value, ?, ? FROM document_local_archives a, json_each(a.payload, '$.updates')
                        WHERE a.id = ? AND a.workspace_id = ? AND a.meetingId = ?
                        """, arguments: [document.id, workspace.accountConnectionId != nil, now, meetingID, orphan.workspaceID, meetingID])
                    }
                    var record = DocumentUpdateRecord(
                        documentId: document.id,
                        payload: update,
                        pending: local && workspace.accountConnectionId != nil,
                        createdAt: now
                    )
                    try record.insert(db)
                    if let recovery {
                        try DocumentRecoveryRecord(
                            id: .v7(),
                            documentId: document.id,
                            blocksJSON: recovery,
                            reason: "concurrent_delete",
                            pending: workspace.accountConnectionId != nil,
                            createdAt: now
                        )
                        .insert(db)
                    }
                    if local {
                        try WorkspaceTransferFence.recordLocalMutation(workspaceID: workspace.id, in: db)
                        try db.execute(
                            sql: "UPDATE documents SET locallyEdited = 1, updatedAt = ?, lastAccessedAt = ? WHERE id = ?",
                            arguments: [now, now, document.id]
                        )
                    }
                    return false
                }
                if privateCopy { throw DocumentCoreError.editPreservedPrivately }
                return
            } catch AppendRetry.changed { try Task.checkCancellation() }
        }
    }

    func materialize(meetingID: UUID, compact: Bool = false) async throws -> DocumentCoreResult {
        try await materialize(reference: .notes(meetingID), compact: compact)
    }

    func materialize(documentID: UUID, compact: Bool = false) async throws -> DocumentCoreResult {
        try await materialize(reference: .document(documentID), compact: compact)
    }

    private enum Reference: Sendable {
        case notes(UUID), document(UUID)
        func load(in db: Database) throws -> DocumentRecord? {
            switch self {
            case let .notes(id): try DocumentRecord.notes(in: db, meetingID: id)
            case let .document(id): try DocumentRecord.fetchOne(db, key: id)
            }
        }
    }

    private func materialize(reference: Reference, compact: Bool) async throws -> DocumentCoreResult {
        while true {
            let source = try await dbQueue.read { db -> (DocumentRecord?, [DocumentUpdateRecord], Bool) in
                let record = try reference.load(in: db)
                let updates = try DocumentUpdateRecord.filter(Column("documentId") == record?.id)
                    .filter(Column("id") > (record?.checkpointSequence ?? 0)).order(Column("id")).fetchAll(db)
                let local = try record.flatMap { try WorkspaceRecord.fetchOne(db, key: $0.workspaceId) }?.accountConnectionId == nil
                return (record, updates, local)
            }
            if let record = source.0, !record.resident { throw DocumentCoreError.unavailable }
            if let record = source.0, record.schemaVersion != 2 { throw DocumentCoreError.unsupportedSchema }
            let result = try await core.process(DocumentCoreCommand(
                checkpoint: source.0?.checkpoint, updates: source.1.map(\.payload),
                purgeBefore: source.2 ? Date().addingTimeInterval(-86400).timeIntervalSince1970 * 1000 : nil
            ))
            guard let record = source.0 else { return result }
            let through = source.1.last?.id ?? record.checkpointSequence
            let purged = result.purged == true
            if !compact, !purged, source.1.isEmpty, record.projectionSequence == through { return result }
            let recoveryJSON = try result.removed.isEmpty ? nil : String(decoding: JSONEncoder().encode(result.removed), as: UTF8.self)
            let committed = try await dbQueue.write { db -> Bool in
                guard let current = try reference.load(in: db),
                      current.id == record.id,
                      current.checkpointSequence == record.checkpointSequence,
                      current.checkpoint == record.checkpoint,
                      current.generation == record.generation,
                      current.workspaceId == record.workspaceId,
                      let workspace = try WorkspaceRecord.fetchOne(db, key: current.workspaceId),
                      (workspace.accountConnectionId == nil) == source.2 else { return false }
                if purged {
                    let latest = try Int64.fetchOne(db, sql: "SELECT max(id) FROM document_updates WHERE documentId = ?", arguments: [record.id]) ?? 0
                    guard latest <= through else { return false }
                }
                let pending = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM document_updates WHERE documentId = ? AND pending = 1)",
                    arguments: [record.id]
                ) == true
                let preservesRecovery = recoveryJSON != nil && (source.2 || pending)
                if preservesRecovery, let recoveryJSON {
                    try DocumentRecoveryRecord(
                        id: .v7(),
                        documentId: record.id,
                        blocksJSON: recoveryJSON,
                        reason: "deleted",
                        pending: !source.2,
                        createdAt: Date()
                    ).insert(db)
                }
                // The checkpoint includes exactly `through`. Later durable appends remain in the log.
                let recording = try RecordingSessionRecord.hasActiveRecording(workspaceId: record.workspaceId, in: db)
                // A Server replica must also preserve unsent deletions before compaction or conversion to Local.
                // The checkpoint, not the projection watermark, is the recovery's atomic causal baseline.
                if compact || purged || preservesRecovery || (source.1.count >= 32 && !recording) {
                    try db.execute(
                        sql: "UPDATE documents SET checkpoint = ?, checkpointSequence = ?, projectionSequence = ?, text = ? WHERE id = ?",
                        arguments: [result.checkpoint, through, through, result.projection.text, record.id]
                    )
                    try db.execute(
                        sql: "DELETE FROM document_updates WHERE documentId = ? AND id <= ? AND pending = 0",
                        arguments: [record.id, through]
                    )
                } else {
                    try db.execute(
                        sql: "UPDATE documents SET projectionSequence = ?, text = ? WHERE id = ?",
                        arguments: [through, result.projection.text, record.id]
                    )
                }
                return true
            }
            if committed { return result }
            try Task.checkCancellation()
        }
    }

    func receive(
        document: DocumentRecord,
        update: String,
        generation: UUID,
        revision: Int,
        validate: @escaping @Sendable (Database) throws -> Void
    ) async throws {
        let reference: Reference = if document.kind == "notes",
                                      let meetingID = document.meetingId { .notes(meetingID) } else { .document(document.id) }
        while true {
            let source = try await dbQueue.read { db -> (DocumentRecord?, [DocumentUpdateRecord], Int64) in
                try validate(db)
                let record = try reference.load(in: db)
                let updates = try DocumentUpdateRecord.filter(Column("documentId") == record?.id)
                    .filter(Column("id") > (record?.checkpointSequence ?? 0)).order(Column("id")).fetchAll(db)
                let latest = try Int64.fetchOne(db, sql: "SELECT max(id) FROM document_updates WHERE documentId = ?", arguments: [record?.id]) ?? 0
                return (record, updates, latest)
            }
            let before = try await core.process(DocumentCoreCommand(checkpoint: source.0?.checkpoint, updates: source.1.map(\.payload)))
            let merged = try await core.process(DocumentCoreCommand(checkpoint: before.checkpoint, updates: [update]))
            // A pending deletion may not have been projected yet. Preserve its hidden body
            // too, unless the incoming merge restored it or already supplies its newer copy.
            let mergedIDs = Set((merged.projection.blocks + merged.removed).map(\.id))
            let removed = merged.removed + before.removed.filter { !mergedIDs.contains($0.id) }
            let recoveryJSON = try removed.isEmpty ? nil : String(
                decoding: JSONEncoder().encode(removed),
                as: UTF8.self
            )
            let committed = try await dbQueue.write { db -> Bool in
                try validate(db)
                let existing = try reference.load(in: db)
                guard existing?.id == source.0?.id,
                      existing?.checkpointSequence == source.0?.checkpointSequence,
                      existing?.checkpoint == source.0?.checkpoint,
                      existing?.generation == source.0?.generation else { return false }
                let latest = try Int64.fetchOne(db, sql: "SELECT max(id) FROM document_updates WHERE documentId = ?", arguments: [existing?.id]) ?? 0
                guard latest == source.2 else { return false }
                // An authorized reread after restoration changes the send generation, not Yjs causality.
                // Keep local structs/outbox because a still-open editor's next delta depends on them.
                let nextRevision = existing?.generation == generation ? max(existing?.revision ?? 0, revision) : revision
                let now = Date()
                if let existing, existing.id != document.id {
                    // Cascading foreign keys preserve updates and recoveries under the canonical ID.
                    try db.execute(sql: "UPDATE documents SET id = ? WHERE id = ?", arguments: [document.id, existing.id])
                } else if existing == nil {
                    var row = document
                    row.checkpoint = before.checkpoint
                    row.text = before.projection.text
                    row.revision = 0
                    try row.insert(db)
                }
                try db.execute(
                    sql: "UPDATE documents SET workspace_id = ?, title = ? WHERE id = ?",
                    arguments: [document.workspaceId, document.title, document.id]
                )
                // Query at commit, including pending entries already incorporated into the checkpoint.
                let pending = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM document_updates WHERE documentId = ? AND pending = 1)",
                    arguments: [document.id]
                ) == true
                let preservesRecovery = recoveryJSON != nil && pending
                if preservesRecovery, let recoveryJSON {
                    try DocumentRecoveryRecord(
                        id: .v7(),
                        documentId: document.id,
                        blocksJSON: recoveryJSON,
                        reason: "concurrent_delete",
                        pending: true,
                        createdAt: now
                    ).insert(db)
                }
                if merged.checkpoint != before.checkpoint {
                    var entry = DocumentUpdateRecord(documentId: document.id, payload: update, pending: false, createdAt: now)
                    try entry.insert(db)
                    try db.execute(
                        sql: "UPDATE documents SET projectionSequence = ?, text = ? WHERE id = ?",
                        arguments: [entry.id, merged.projection.text, document.id]
                    )
                }
                if preservesRecovery {
                    // The receive recovery and its baseline must advance together, just as in materialize.
                    let through = try Int64
                        .fetchOne(db, sql: "SELECT max(id) FROM document_updates WHERE documentId = ?", arguments: [document.id]) ?? 0
                    try db.execute(
                        sql: "UPDATE documents SET checkpoint = ?, checkpointSequence = ? WHERE id = ?",
                        arguments: [merged.checkpoint, through, document.id]
                    )
                    try db.execute(
                        sql: "DELETE FROM document_updates WHERE documentId = ? AND id <= ? AND pending = 0",
                        arguments: [document.id, through]
                    )
                }
                try db.execute(
                    sql: """
                    UPDATE documents SET generation = ?, revision = ?, resident = 1,
                        lastAccessedAt = CASE WHEN resident = 0 THEN ? ELSE coalesce(lastAccessedAt, ?) END WHERE id = ?
                    """,
                    arguments: [generation, nextRevision, now, now, document.id]
                )
                return true
            }
            if committed { return }
            try Task.checkCancellation()
        }
    }

    func insertRecoveredText(meetingID: UUID, text: String) async throws {
        let before = try await materialize(meetingID: meetingID)
        let result = try await core.process(DocumentCoreCommand(checkpoint: before.checkpoint, text: text, vector: before.vector))
        try await append(meetingID: meetingID, update: result.update, local: true)
    }

    func legacyImport(text: String) async throws -> String {
        try await core.process(DocumentCoreCommand(text: text)).checkpoint
    }

    func recoveries(meetingID: UUID) async throws -> ([DocumentRecoveryRecord], [UUID: String]) {
        let records = try await dbQueue.read { db in
            try DocumentRecoveryRecord.filter(Column("documentId") == DocumentRecord.notes(in: db, meetingID: meetingID)?.id)
                .order(Column("createdAt").desc).fetchAll(db)
        }
        let text = try Dictionary(uniqueKeysWithValues: records.map { record in
            let blocks = try JSONDecoder().decode([DocumentBlock].self, from: Data(record.blocksJSON.utf8))
            return (record.id, blocks.map(\.text).joined(separator: "\n"))
        })
        return (records, text)
    }

    func archives(workspaceID: UUID) async throws -> [(UUID, String, String)] {
        struct Payload: Decodable {
            let checkpoint: String?
            let updates: [String]
            let copies: [String]
            let recoveries: [[DocumentBlock]]
            let legacy: String?
        }
        let records = try await dbQueue.read { db in
            try DocumentLocalArchiveRecord.filter(Column("workspace_id") == workspaceID).order(Column("createdAt").desc).fetchAll(db)
        }
        var result: [(UUID, String, String)] = []
        for record in records {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(record.payload.utf8))
            var text: String
            do {
                text = try await core.process(DocumentCoreCommand(checkpoint: payload.checkpoint, updates: payload.updates)).projection.text
            } catch DocumentCoreError.unsupportedSchema {
                text = L10n.documentUnsupportedSchema
            } catch {
                text = L10n.documentSaveFailed
            }
            for copy in payload.copies {
                // A late edit can depend on the pre-transfer private checkpoint rather than the new shared document.
                do {
                    try await text += "\n\n" + (core.process(DocumentCoreCommand(checkpoint: copy, updates: payload.updates)).projection.text)
                } catch DocumentCoreError.unsupportedSchema {
                    text += "\n\n" + L10n.documentUnsupportedSchema
                } catch {
                    text += "\n\n" + L10n.documentSaveFailed
                }
            }
            text += "\n\n" + payload.recoveries.flatMap(\.self).map(\.text).joined(separator: "\n")
            if let legacy = payload.legacy { text += "\n\n" + legacy }
            result.append((record.id, record.name, text))
        }
        return result
    }

    func prepareAccountTransfer(workspaceID: UUID) async throws {
        try await DocumentEditorModel.finishLocalSaves(dbQueue: dbQueue)
        let ids = try await dbQueue.read { db in
            try UUID.fetchAll(
                db,
                sql: "SELECT id FROM documents WHERE workspace_id = ?",
                arguments: [workspaceID]
            )
        }
        for id in ids {
            _ = try await materialize(documentID: id, compact: true)
        }
    }

    nonisolated static func preservePrivateCopies(workspaceID: UUID, in db: Database) throws {
        let documents = try DocumentRecord.fetchAll(
            db,
            sql: "SELECT * FROM documents WHERE workspace_id = ?",
            arguments: [workspaceID]
        )
        for document in documents {
            let latest = try Int64.fetchOne(db, sql: "SELECT max(id) FROM document_updates WHERE documentId = ?", arguments: [document.id]) ?? 0
            guard latest <= document.checkpointSequence else { throw LocalWorkspaceImportError.changed }
            try DocumentPrivateCopyRecord(
                id: .v7(),
                workspaceId: document.workspaceId,
                meetingId: document.meetingId,
                kind: document.kind,
                title: document.title,
                checkpoint: document.checkpoint,
                text: document.text,
                createdAt: document.createdAt,
                updatedAt: document.updatedAt
            ).insert(db)
            try DocumentRetention.archive(documentID: document.id, in: db)
            try document.delete(db)
            try db.execute(sql: "DELETE FROM document_legacy_imports WHERE meetingId = ?", arguments: [document.meetingId])
        }
    }
}
