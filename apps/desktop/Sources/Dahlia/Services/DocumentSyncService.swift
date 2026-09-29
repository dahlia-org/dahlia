import DahliaServerAPI
import Foundation
import GRDB

actor DocumentSyncService {
    struct Target: Sendable {
        let workspaceID: UUID
        let meetingID: UUID
        let connectionID: UUID
        let origin: URL
        let mutationGeneration: Int64

        func validate(in db: Database) throws {
            guard try SyncTransactionQueue.matchesExpectedConnection(workspaceId: workspaceID, connectionId: connectionID, in: db),
                  try Int64
                  .fetchOne(db, sql: "SELECT syncMutationGeneration FROM workspaces WHERE id = ?", arguments: [workspaceID]) == mutationGeneration,
                  try MeetingRecord.fetchOne(db, key: meetingID)?.workspaceId == workspaceID else { throw CancellationError() }
        }
    }

    private struct RemoteDocument: Decodable {
        let generation: UUID
        let revision: Int
        let checkpoint: String
        let text: String
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
            return Target(workspaceID: workspace.id, meetingID: meetingID, connectionID: connectionID, origin: origin, mutationGeneration: generation)
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
            try DocumentUpdateRecord.filter(Column("meetingId") == meetingID).filter(Column("pending") == true).fetchCount(db) > 0
        })
    }

    private func exchange(meetingID: UUID) async throws {
        guard let target = try await target(meetingID: meetingID) else { return }
        if !capableConnections.contains(target.connectionID) {
            let data = try await api.data(origin: target.origin, connectionId: target.connectionID) {
                try await $0.getCapabilities().ok.body.json
            }
            guard try JSONDecoder().decode(ServerCapabilities.self, from: data).documents?.version == 1 else {
                throw SyncHTTPError(status: 426, body: Data())
            }
            capableConnections.insert(target.connectionID)
        }
        let resident = try await dbQueue.read { try DocumentRecord.fetchOne($0, key: meetingID)?.resident ?? true }
        let state = resident ? try await persistence.prepare(meetingID: meetingID) : try await worker.process(DocumentCoreCommand())
        let source = try await dbQueue.read { db -> (DocumentRecord?, [DocumentUpdateRecord]) in
            try target.validate(in: db)
            return try (
                DocumentRecord.fetchOne(db, key: meetingID),
                DocumentUpdateRecord.filter(Column("meetingId") == meetingID)
                    .filter(Column("pending") == true).order(Column("id")).fetchAll(db)
            )
        }
        let workspaceID = target.workspaceID.uuidString.lowercased(), documentID = meetingID.uuidString.lowercased()
        var generation = resident ? source.0?.generation : nil
        if generation == nil {
            let response = try await api.data(origin: target.origin, connectionId: target.connectionID, maximumBytes: DocumentLimits.responseBytes) {
                try await $0.getDocument(path: .init(workspaceId: workspaceID, documentId: documentID)).ok.body.json
            }
            var remote = try JSONDecoder().decode(Envelope.self, from: response).document
            if remote == nil, !source.1.isEmpty {
                let response = try await api.data(
                    origin: target.origin,
                    connectionId: target.connectionID,
                    maximumBytes: DocumentLimits.responseBytes
                ) {
                    try await $0.initializeDocument(path: .init(workspaceId: workspaceID, documentId: documentID), body: .json(.init())).ok.body.json
                }
                remote = try JSONDecoder().decode(Envelope.self, from: response).document
            }
            guard let remote else { return }
            try await persistence.receive(
                meetingID: meetingID,
                update: remote.checkpoint,
                generation: remote.generation,
                revision: remote.revision,
                validate: target.validate
            )
            generation = remote.generation
        }
        guard let generation else { return }
        let batch = try await worker.process(DocumentCoreCommand(pending: source.1.compactMap { entry in
            entry.id.map { DocumentCoreCommand.Pending(sequence: $0, update: entry.payload) }
        })).batch
        let payload = batch?.update
        let response: Data
        do { response = try await api.data(origin: target.origin, connectionId: target.connectionID, maximumBytes: DocumentLimits.responseBytes) {
            try await $0.exchangeDocument(
                path: .init(workspaceId: workspaceID, documentId: documentID),
                body: .json(.init(generation: generation.uuidString.lowercased(), vector: state.vector, update: payload))
            )
            .ok.body.json
        }
        } catch let error as SyncHTTPError where error.status == 409 {
            let fresh = try await api.data(origin: target.origin, connectionId: target.connectionID, maximumBytes: DocumentLimits.responseBytes) {
                try await $0.getDocument(path: .init(workspaceId: workspaceID, documentId: documentID)).ok.body.json
            }
            guard let remote = try JSONDecoder().decode(Envelope.self, from: fresh).document else { throw error }
            try await persistence.receive(
                meetingID: meetingID,
                update: remote.checkpoint,
                generation: remote.generation,
                revision: remote.revision,
                validate: target.validate
            )
            return
        }
        let result = try JSONDecoder().decode(Exchange.self, from: response)
        try await persistence.receive(
            meetingID: meetingID,
            update: result.update,
            generation: result.generation,
            revision: result.revision,
            validate: target.validate
        )
        if let through = batch?.through {
            try await dbQueue.write { db in
                try target.validate(in: db)
                try db.execute(sql: "UPDATE document_updates SET pending = 0 WHERE meetingId = ? AND id <= ?", arguments: [meetingID, through])
            }
        }
        try await recoveries(target)
    }

    func presence(meetingID: UUID, sessionID: UUID, editing: Bool) async throws -> [String] {
        if let cached = lastPresence[meetingID], Date().timeIntervalSince(cached.0) < 5 { return cached.1 }
        guard let target = try await target(meetingID: meetingID),
              try await dbQueue.read({ try DocumentRecord.fetchOne($0, key: meetingID)?.generation }) != nil else { return [] }
        let data = try await api.data(origin: target.origin, connectionId: target.connectionID) { client in
            let path = target.workspaceID.uuidString.lowercased(), id = meetingID.uuidString.lowercased()
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

    private func recoveries(_ target: Target) async throws {
        let pending = try await dbQueue.read { db in
            try DocumentRecoveryRecord.filter(Column("meetingId") == target.meetingID).filter(Column("pending") == true).fetchAll(db)
        }
        let workspace = target.workspaceID.uuidString.lowercased(), document = target.meetingID.uuidString.lowercased()
        for entry in pending {
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
                    meetingId: target.meetingID,
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

    /// Revision discovery is independent of domain receipts. Download only changed or pending documents.
    private func discover() async throws -> [UUID] {
        let workspaces = try await dbQueue.read { db in
            try WorkspaceRecord.filter(Column("accountConnectionId") != nil).fetchAll(db)
        }
        var ids = try await dbQueue.read { db in
            try UUID.fetchAll(
                db,
                sql: "SELECT DISTINCT meetingId FROM document_updates WHERE pending = 1 UNION SELECT DISTINCT meetingId FROM document_recoveries WHERE pending = 1"
            )
        }
        struct Page: Decodable {
            struct Item: Decodable { let id: UUID
                let revision: Int
                let generation: UUID
            }

            let items: [Item]
            let nextCursor: String?
        }
        for workspace in workspaces {
            try Task.checkCancellation()
            guard let connectionID = workspace.accountConnectionId,
                  let origin = try await dbQueue.read({ db in
                      try String.fetchOne(db, sql: "SELECT origin FROM dahlia_account_connections WHERE id = ?", arguments: [connectionID])
                          .flatMap(URL.init(string:))
                  }) else { continue }
            do {
                var after: String?
                repeat {
                    let cursor = after
                    let data = try await api.data(origin: origin, connectionId: connectionID) {
                        try await $0.listDocuments(path: .init(workspaceId: workspace.id.uuidString.lowercased()), query: .init(after: cursor)).ok
                            .body.json
                    }
                    let page = try JSONDecoder().decode(Page.self, from: data)
                    ids += try await dbQueue.read { db in
                        try page.items.compactMap { item in
                            guard try MeetingRecord.fetchOne(db, key: item.id)?.workspaceId == workspace.id else { return nil }
                            let local = try DocumentRecord.fetchOne(db, key: item.id)
                            if let local, !local.resident { return nil }
                            return local?.generation == item.generation && local?.revision == item.revision ? nil : item.id
                        }
                    }
                    after = page.nextCursor
                } while after != nil && !Task.isCancelled
            } catch { continue }
        }
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    /// Independent, bounded lanes: neither a failed document nor domain transaction blocks the others.
    func run() async {
        while !Task.isCancelled {
            let meetings = await (try? discover()) ?? []
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                var iterator = meetings.makeIterator()
                for _ in 0 ..< 4 {
                    if let id = iterator.next() { group.addTask { try? await self.synchronize(meetingID: id) } }
                }
                while await group.next() != nil {
                    if Task.isCancelled { group.cancelAll()
                        break
                    }
                    if let id = iterator.next() { group.addTask { try? await self.synchronize(meetingID: id) } }
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
