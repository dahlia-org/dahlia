import DahliaServerAPI
import Foundation
import GRDB

actor DocumentSyncService {
    struct Target: Sendable {
        let workspaceID: UUID
        let meetingID: UUID?
        let documentID: UUID?
        let kind: String
        let connectionID: UUID
        let origin: URL
        let mutationGeneration: Int64

        func document(in db: Database) throws -> DocumentRecord? {
            if kind == "notes", let meetingID { return try DocumentRecord.notes(in: db, meetingID: meetingID) }
            return try documentID.flatMap { try DocumentRecord.fetchOne(db, key: $0) }
        }

        func validate(in db: Database) throws {
            guard try SyncTransactionQueue.matchesExpectedConnection(workspaceId: workspaceID, connectionId: connectionID, in: db),
                  try Int64
                  .fetchOne(db, sql: "SELECT syncMutationGeneration FROM workspaces WHERE id = ?", arguments: [workspaceID]) == mutationGeneration,
                  try (meetingID.map { try MeetingRecord.fetchOne(db, key: $0)?.workspaceId == workspaceID } ?? true)
            else { throw CancellationError() }
            if let existing = try document(in: db), existing.workspaceId != workspaceID {
                guard try SyncTransactionQueue.matchesExpectedConnection(workspaceId: existing.workspaceId, connectionId: connectionID, in: db)
                else { throw CancellationError() }
            }
        }

        func validate(remote: RemoteDocument) throws {
            guard remote.workspaceId == workspaceID, remote.meetingId == meetingID,
                  remote.kind == kind else { throw DocumentCoreError.invalidCommand }
        }
    }

    struct RemoteDocument: Decodable {
        let id: UUID
        let workspaceId: UUID
        let meetingId: UUID?
        let kind: String
        let title: String
        let generation: UUID
        let revision: Int
        let checkpoint: String
        let text: String
        let createdAt: Date
        let updatedAt: Date
        var record: DocumentRecord {
            DocumentRecord(
                id: id,
                workspaceId: workspaceId,
                meetingId: meetingId,
                kind: kind,
                title: title,
                revision: revision,
                generation: generation,
                checkpoint: checkpoint,
                text: text,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            return try Date(value, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon))
        }
        return decoder
    }

    private struct Envelope: Decodable { let document: RemoteDocument? }
    private struct Exchange: Decodable { let generation: UUID
        let revision: Int
        let update: String
    }

    private let dbQueue: DatabaseQueue
    private let api: SyncAPIClient
    private let persistence: DocumentPersistence
    private let worker = DocumentCoreWorker()
    deinit { worker.stop() }
    private var capableConnections: Set<UUID> = []
    private var lastPresence: [UUID: (Date, [String])] = [:]
    private var inFlight: [UUID: Task<Void, any Error>] = [:]

    init(dbQueue: DatabaseQueue, api: SyncAPIClient = SyncAPIClient(session: .shared)) {
        self.dbQueue = dbQueue
        self.api = api
        persistence = DocumentPersistence(dbQueue: dbQueue)
    }

    func target(meetingID: UUID) async throws -> Target? {
        try await dbQueue.read { db in
            guard let meeting = try MeetingRecord.fetchOne(db, key: meetingID),
                  let workspace = try WorkspaceRecord.fetchOne(db, key: meeting.workspaceId),
                  let connectionID = workspace.accountConnectionId else { return nil }
            guard let origin = try String.fetchOne(db, sql: "SELECT origin FROM dahlia_account_connections WHERE id = ?", arguments: [connectionID])
                .flatMap(URL.init(string:)),
                let generation = try Int64
                .fetchOne(db, sql: "SELECT syncMutationGeneration FROM workspaces WHERE id = ?", arguments: [workspace.id])
            else { throw DocumentCoreError.unavailable }
            return try Target(
                workspaceID: workspace.id,
                meetingID: meetingID,
                documentID: DocumentRecord.notes(in: db, meetingID: meetingID)?.id,
                kind: "notes",
                connectionID: connectionID,
                origin: origin,
                mutationGeneration: generation
            )
        }
    }

    func synchronize(meetingID: UUID) async throws {
        try Task.checkCancellation()
        let ownsExchange = inFlight[meetingID] == nil
        let task = inFlight[meetingID] ?? Task { try await exchange(meetingID: meetingID) }
        inFlight[meetingID] = task
        defer { if ownsExchange { inFlight[meetingID] = nil } }
        // Task.value does not propagate cancellation to an unstructured shared exchange.
        // Cancelling any waiter stops transport; its durable outbox remains retryable.
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            task.cancel()
        }
    }

    func flush(meetingID: UUID) async throws {
        try await DocumentEditorModel.finishLocalSaves(dbQueue: dbQueue, meetingID: meetingID)
        guard try await target(meetingID: meetingID) != nil else { return }
        repeat {
            try await synchronize(meetingID: meetingID)
        } while try await dbQueue.read({ db in
            guard let document = try DocumentRecord.notes(in: db, meetingID: meetingID),
                  try DocumentUpdateRecord.filter(Column("documentId") == document.id)
                  .filter(Column("pending") == true).fetchCount(db) > 0 else { return false }
            guard try WorkspaceRecord.fetchOne(db, key: document.workspaceId)?.allowsCanonicalEdits == true else {
                throw SyncHTTPError(status: 403, body: Data("{\"error\":\"document_read_only\"}".utf8))
            }
            return true
        })
    }

    private func exchange(meetingID: UUID) async throws {
        guard let target = try await target(meetingID: meetingID) else { return }
        try await exchange(target: target)
    }

    private func exchange(target: Target) async throws {
        if !capableConnections.contains(target.connectionID) {
            let data = try await api.data(origin: target.origin, connectionId: target.connectionID) {
                try await $0.getCapabilities().ok.body.json
            }
            guard try JSONDecoder().decode(ServerCapabilities.self, from: data).documents?.version == 1 else {
                throw SyncHTTPError(status: 426, body: Data())
            }
            capableConnections.insert(target.connectionID)
        }
        let resident = try await dbQueue.read { try target.document(in: $0)?.resident ?? true }
        let state: DocumentCoreResult
        if !resident {
            state = try await worker.process(DocumentCoreCommand())
        } else if target.kind == "notes", let meetingID = target.meetingID {
            state = try await persistence.prepare(meetingID: meetingID)
        } else if let documentID = target.documentID {
            state = try await persistence.materialize(documentID: documentID)
        } else {
            return
        }
        let source = try await dbQueue.read { db -> (DocumentRecord?, [DocumentUpdateRecord], Bool) in
            try target.validate(in: db)
            let document = try target.document(in: db)
            return try (
                document,
                DocumentUpdateRecord.filter(Column("documentId") == document?.id)
                    .filter(Column("pending") == true).order(Column("id")).fetchAll(db),
                WorkspaceRecord.fetchOne(db, key: target.workspaceID)?.allowsCanonicalEdits == true
            )
        }
        let workspaceID = target.workspaceID.uuidString.lowercased()
        var documentID = source.0?.id ?? target.documentID ?? .v7()
        var generation = resident && source.0?.workspaceId == target.workspaceID ? source.0?.generation : nil
        if generation == nil {
            let proposedID = documentID.uuidString.lowercased()
            let response = try await api.data(origin: target.origin, connectionId: target.connectionID, maximumBytes: DocumentLimits.responseBytes) {
                if target.kind == "notes", let meetingID = target.meetingID {
                    return try await $0.getMeetingNotes(path: .init(workspaceId: workspaceID, meetingId: meetingID.uuidString.lowercased())).ok.body
                        .json
                }
                return try await $0.getDocument(path: .init(workspaceId: workspaceID, documentId: proposedID)).ok.body.json
            }
            var remote = try Self.decoder().decode(Envelope.self, from: response).document
            if remote == nil, source.2, !source.1.isEmpty, let meetingID = target.meetingID, target.kind == "notes" {
                let response = try await api.data(
                    origin: target.origin,
                    connectionId: target.connectionID,
                    maximumBytes: DocumentLimits.responseBytes
                ) {
                    try await $0.initializeMeetingNotes(
                        path: .init(workspaceId: workspaceID, meetingId: meetingID.uuidString.lowercased()),
                        body: .json(.init(id: proposedID))
                    ).ok.body.json
                }
                remote = try Self.decoder().decode(Envelope.self, from: response).document
            }
            guard let remote else { return }
            try target.validate(remote: remote)
            documentID = remote.id
            try await persistence.receive(
                document: remote.record,
                update: remote.checkpoint,
                generation: remote.generation,
                revision: remote.revision,
                validate: target.validate
            )
            generation = remote.generation
        }
        guard let generation else { return }
        let canonicalID = documentID.uuidString.lowercased()
        // Revoked edits remain locally readable and retryable if permission is restored.
        // A viewer still receives remote changes, without publishing or acknowledging their pending bytes.
        let batch = try await worker.process(DocumentCoreCommand(pending: source.2 ? source.1.compactMap { entry in
            entry.id.map { DocumentCoreCommand.Pending(sequence: $0, update: entry.payload) }
        } : [])).batch
        let payload = batch?.update
        let response: Data
        do { response = try await api.data(origin: target.origin, connectionId: target.connectionID, maximumBytes: DocumentLimits.responseBytes) {
            try await $0.exchangeDocument(
                path: .init(workspaceId: workspaceID, documentId: canonicalID),
                body: .json(.init(generation: generation.uuidString.lowercased(), vector: state.vector, update: payload))
            )
            .ok.body.json
        }
        } catch let error as SyncHTTPError where error.status == 409 {
            let fresh = try await api.data(origin: target.origin, connectionId: target.connectionID, maximumBytes: DocumentLimits.responseBytes) {
                try await $0.getDocument(path: .init(workspaceId: workspaceID, documentId: canonicalID)).ok.body.json
            }
            guard let remote = try Self.decoder().decode(Envelope.self, from: fresh).document else { throw error }
            try target.validate(remote: remote)
            try await persistence.receive(
                document: remote.record,
                update: remote.checkpoint,
                generation: remote.generation,
                revision: remote.revision,
                validate: target.validate
            )
            return
        }
        let result = try JSONDecoder().decode(Exchange.self, from: response)
        guard let current = try await dbQueue.read({ try target.document(in: $0) }) else { throw CancellationError() }
        try await persistence.receive(
            document: current,
            update: result.update,
            generation: result.generation,
            revision: result.revision,
            validate: target.validate
        )
        if let through = batch?.through {
            try await dbQueue.write { db in
                try target.validate(in: db)
                try db.execute(sql: "UPDATE document_updates SET pending = 0 WHERE documentId = ? AND id <= ?", arguments: [current.id, through])
            }
        }
        try await recoveries(target, documentID: current.id, canWrite: source.2)
    }

    func presence(meetingID: UUID, sessionID: UUID, editing: Bool) async throws -> [String] {
        if let cached = lastPresence[meetingID], Date().timeIntervalSince(cached.0) < 5 { return cached.1 }
        guard let target = try await target(meetingID: meetingID),
              try await dbQueue.read({ try target.document(in: $0)?.generation }) != nil else { return [] }
        guard let documentID = try await dbQueue.read({ try target.document(in: $0)?.id }) else { return [] }
        let data = try await api.data(origin: target.origin, connectionId: target.connectionID) { client in
            let path = target.workspaceID.uuidString.lowercased(), id = documentID.uuidString.lowercased()
            if editing {
                return try await client.updateDocumentPresence(
                    path: .init(workspaceId: path, documentId: id),
                    body: .json(.init(sessionId: sessionID.uuidString.lowercased()))
                ).ok.body.json
            }
            return try await client.getDocumentPresence(path: .init(workspaceId: path, documentId: id)).ok.body.json
        }
        struct People: Decodable { struct Person: Decodable { let name: String }
            let items: [Person]
        }
        let names = try JSONDecoder().decode(People.self, from: data).items.map(\.name)
        lastPresence[meetingID] = (Date(), names)
        return names
    }

    private func recoveries(_ target: Target, documentID: UUID, canWrite: Bool) async throws {
        let pending = try await dbQueue.read { db in
            try DocumentRecoveryRecord.filter(Column("documentId") == documentID).filter(Column("pending") == true).fetchAll(db)
        }
        let workspace = target.workspaceID.uuidString.lowercased(), document = documentID.uuidString.lowercased()
        for entry in pending where canWrite {
            let blocks = try JSONDecoder().decode([DocumentBlock].self, from: Data(entry.blocksJSON.utf8))
            struct Payload: Encodable { let id: UUID
                let reason: String
                let blocks: [DocumentBlock]
            }
            let body = try JSONDecoder().decode(
                Components.Schemas.DocumentRecovery.self,
                from: JSONEncoder().encode(Payload(id: entry.id, reason: entry.reason, blocks: blocks))
            )
            _ = try await api.data(origin: target.origin, connectionId: target.connectionID) {
                try await $0.saveDocumentRecovery(path: .init(workspaceId: workspace, documentId: document), body: .json(body)).ok.body.json
            }
            try await dbQueue.write { db in
                try target.validate(in: db)
                try db.execute(sql: "UPDATE document_recoveries SET pending = 0 WHERE id = ?", arguments: [entry.id])
            }
        }
        struct Page: Decodable {
            struct Item: Decodable { let id: UUID
                let reason: String
                let blocks: [DocumentBlock]
                let createdAt: String
            }

            let items: [Item]
            let nextCursor: String?
        }
        var after: String?
        repeat {
            let cursor = after
            let data = try await api.data(origin: target.origin, connectionId: target.connectionID, maximumBytes: DocumentLimits.responseBytes) {
                try await $0.listDocumentRecoveries(path: .init(workspaceId: workspace, documentId: document), query: .init(after: cursor)).ok.body
                    .json
            }
            let page = try JSONDecoder().decode(Page.self, from: data)
            let rows = try page.items.map { item in
                let date = try Date(
                    item.createdAt,
                    strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon)
                )
                return try DocumentRecoveryRecord(
                    id: item.id,
                    documentId: documentID,
                    blocksJSON: String(decoding: JSONEncoder().encode(item.blocks), as: UTF8.self),
                    reason: item.reason,
                    pending: false,
                    createdAt: date
                )
            }
            try await dbQueue.write { db in
                try target.validate(in: db)
                for row in rows {
                    try row.insert(db, onConflict: .ignore)
                }
            }
            after = page.nextCursor
        } while after != nil
    }

    func synchronizeWorkspace(workspaceID: UUID) async throws {
        let targets = try await discover(workspaceID: workspaceID, includeEvicted: true)
        for target in targets {
            try await synchronize(target: target)
        }
    }

    private func synchronize(target: Target) async throws {
        if target.kind == "notes", let meetingID = target.meetingID { return try await synchronize(meetingID: meetingID) }
        guard let id = target.documentID else { return }
        try Task.checkCancellation()
        let ownsExchange = inFlight[id] == nil
        let task = inFlight[id] ?? Task {
            let generation = try await dbQueue.read { try target.document(in: $0)?.generation }
            do {
                try await exchange(target: target)
            } catch let error as SyncHTTPError where error.status == 404 {
                guard try await removeMissingStandalone(target, generation: generation) else { throw error }
            }
        }
        inFlight[id] = task
        defer { if ownsExchange { inFlight[id] = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// A complete inventory schedules missing caches; only a canonical 404 confirms removal.
    private func removeMissingStandalone(_ target: Target, generation: UUID?) async throws -> Bool {
        guard target.meetingID == nil, let id = target.documentID, let generation else { return false }
        do {
            _ = try await api.data(origin: target.origin, connectionId: target.connectionID, maximumBytes: DocumentLimits.responseBytes) {
                try await $0.getDocument(path: .init(
                    workspaceId: target.workspaceID.uuidString.lowercased(), documentId: id.uuidString.lowercased()
                )).ok.body.json
            }
            return false
        } catch let error as SyncHTTPError where error.status == 404 {
            // A missing old location can be a transfer to a Workspace not discovered yet.
            // Resolve that before turning its still-pending updates into a private archive.
            let data = try await api.data(origin: target.origin, connectionId: target.connectionID) {
                try await $0.getRelocations(path: .init(workspaceId: target.workspaceID.uuidString.lowercased())).ok.body.json
            }
            let relocation = try SyncJSON.decoder.decode(WorkspaceRelocation.self, from: data)
            guard let documents = relocation.documents else { return false }
            return try await dbQueue.write { db in
                try Task.checkCancellation()
                try target.validate(in: db)
                let moved = try WorkspaceRelocation(
                    workspaces: relocation.workspaces, items: [], documents: documents.filter { $0.id == id }
                ).apply(connectionId: target.connectionID, in: db)
                if moved { return true }
                guard let current = try DocumentRecord.fetchOne(db, key: id), current.workspaceId == target.workspaceID,
                      current.generation == generation,
                      try !WorkspaceTransferFence.blocksRemoteChanges(workspaceID: target.workspaceID, in: db) else { return false }
                try DocumentRetention.archive(documentID: id, in: db)
                try current.delete(db)
                return true
            }
        }
    }

    /// Discovery and outboxes share document identities, independent of domain receipts.
    private func discover(workspaceID: UUID? = nil, includeEvicted: Bool = false) async throws -> [Target] {
        let workspaces = try await dbQueue.read { db in
            try WorkspaceRecord.filter(Column("accountConnectionId") != nil)
                .filter(workspaceID.map { Column("id") == $0 } ?? true).fetchAll(db)
        }
        struct Page: Decodable {
            struct Item: Decodable { let id: UUID
                let meetingId: UUID?
                let kind: String
                let revision: Int
                let generation: UUID
            }

            let items: [Item]
            let nextCursor: String?
        }
        var targets: [Target] = []
        var pendingTargets: [Target] = []
        var missingTargets: [Target] = []
        for workspace in workspaces {
            try Task.checkCancellation()
            guard let connectionID = workspace.accountConnectionId,
                  let connection = try await dbQueue.read({ db -> (URL, Int64)? in
                      guard let origin = try String.fetchOne(
                          db,
                          sql: "SELECT origin FROM dahlia_account_connections WHERE id = ?",
                          arguments: [connectionID]
                      ).flatMap(URL.init(string:)),
                          let generation = try Int64.fetchOne(
                              db,
                              sql: "SELECT syncMutationGeneration FROM workspaces WHERE id = ?",
                              arguments: [workspace.id]
                          ) else { return nil }
                      return (origin, generation)
                  }) else { continue }
            let pending = try await dbQueue.read { db in
                try DocumentRecord.fetchAll(db, sql: """
                SELECT d.* FROM documents d WHERE d.workspace_id = ? AND (
                    EXISTS(SELECT 1 FROM document_updates WHERE documentId = d.id AND pending = 1)
                    OR EXISTS(SELECT 1 FROM document_recoveries WHERE documentId = d.id AND pending = 1))
                """, arguments: [workspace.id])
            }
            func target(id: UUID, meeting: UUID?, kind: String) -> Target {
                Target(
                    workspaceID: workspace.id,
                    meetingID: meeting,
                    documentID: id,
                    kind: kind,
                    connectionID: connectionID,
                    origin: connection.0,
                    mutationGeneration: connection.1
                )
            }
            pendingTargets += pending.map { target(id: $0.id, meeting: $0.meetingId, kind: $0.kind) }
            do {
                let cached = try await dbQueue.read { db in
                    try Row.fetchAll(
                        db,
                        sql: "SELECT id, kind FROM documents WHERE workspace_id = ? AND meetingId IS NULL AND generation IS NOT NULL",
                        arguments: [workspace.id]
                    ).map { row -> (id: UUID, kind: String) in (row["id"], row["kind"]) }
                }
                var listed: Set<UUID> = []
                var after: String?
                repeat {
                    let cursor = after
                    let data = try await api.data(origin: connection.0, connectionId: connectionID) {
                        try await $0.listDocuments(path: .init(workspaceId: workspace.id.uuidString.lowercased()), query: .init(after: cursor)).ok
                            .body.json
                    }
                    let page = try JSONDecoder().decode(Page.self, from: data)
                    listed.formUnion(page.items.map(\.id))
                    let changed = try await dbQueue.read { db in
                        try page.items.filter { item in
                            if let meetingID = item.meetingId,
                               try MeetingRecord.fetchOne(db, key: meetingID)?.workspaceId != workspace.id { return false }
                            let local = try item.kind == "notes" ? item.meetingId
                                .flatMap { try DocumentRecord.notes(in: db, meetingID: $0) } : DocumentRecord.fetchOne(
                                    db,
                                    key: item.id
                                )
                            if let local, local.workspaceId != workspace.id { return true }
                            if let local, !local.resident { return includeEvicted }
                            return includeEvicted || local?.generation != item.generation || local?.revision != item.revision
                        }
                    }
                    targets += changed.map { target(id: $0.id, meeting: $0.meetingId, kind: $0.kind) }
                    after = page.nextCursor
                } while after != nil
                missingTargets += cached.filter { !listed.contains($0.id) }.map {
                    target(id: $0.id, meeting: nil, kind: $0.kind)
                }
            } catch { if includeEvicted { throw error } }
        }
        var seen: Set<UUID> = []
        return (targets + pendingTargets + missingTargets).filter { target in
            guard let id = target.kind == "notes" ? target.meetingID : target.documentID else { return false }
            return seen.insert(id).inserted
        }
    }

    /// A failed document never blocks another document or domain synchronization.
    func run() async {
        while !Task.isCancelled {
            let targets = await (try? discover()) ?? []
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                var iterator = targets.makeIterator()
                for _ in 0 ..< 4 {
                    if let target = iterator.next() { group.addTask { try? await self.synchronize(target: target) } }
                }
                while await group.next() != nil {
                    if Task.isCancelled { group.cancelAll()
                        break
                    }
                    if let target = iterator.next() { group.addTask { try? await self.synchronize(target: target) } }
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
