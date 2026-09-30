#if canImport(Testing)
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct WorkspaceImportDestinationTests {
        @Test(arguments: [false, true])
        func retriesCreationAndImportsIntoIndependentDestination(committedBeforeFailure: Bool) async throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "import-destination-\(UUID.v7())")
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appending(path: "source.sqlite").path
            let database = try AppDatabaseManager(path: path)
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://\(UUID.v7()).example.com", clientID: "test", createdAt: .now)
            let source = WorkspaceRecord(id: .v7(), path: nil, name: "Local", createdAt: .now, lastOpenedAt: .now)
            let meeting = MeetingRecord(id: .v7(), workspaceId: source.id, name: "Preserved", createdAt: .now, updatedAt: .now)
            let organization = UUID.v7()
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try source.insert(db)
                try meeting.insert(db)
            }
            struct State: Sendable {
                var requests: [Data] = []
                var workspace: Data?
            }
            let state = Mutex(State())
            ImageURLProtocol.register(origin: connection.origin) { request in
                do {
                    switch request.url!.lastPathComponent {
                    case "transactions":
                        guard let json = ImageURLProtocol.requestJSON(request),
                              let operations = json["operations"] as? [[String: Any]],
                              let payload = operations.first?["data"] as? [String: Any] else { return (400, [:], Data()) }
                        let encoded = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
                        var workspace = payload
                        workspace["workspaceId"] = json["workspaceId"]
                        workspace["organizationName"] = "Organization"
                        workspace["meetingDeletionGraceDays"] = 7
                        workspace["role"] = "admin"
                        workspace["revision"] = 1
                        workspace["updatedAt"] = "2026-09-01T00:00:00Z"
                        let data = try JSONSerialization.data(withJSONObject: workspace)
                        state.withLock {
                            $0.requests.append(encoded)
                            if committedBeforeFailure || $0.requests.count == 2 { $0.workspace = data }
                        }
                        // The commit may succeed while its response is lost. Discovery recovers it on retry.
                        return (500, [:], Data())
                    case "workspaces":
                        let items = try state.withLock { try $0.workspace.map { try [JSONSerialization.jsonObject(with: $0)] } ?? [] }
                        return try (200, [:], JSONSerialization.data(withJSONObject: ["items": items, "nextCursor": NSNull()]))
                    case "capabilities": return (200, [:], Data(#"{"documents":{"version":1},"sync":{"version":7}}"#.utf8))
                    case "snapshot":
                        let data = try #require(state.withLock { $0.workspace })
                        let workspace = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                        return try (200, [:], JSONSerialization.data(withJSONObject: [
                            "items": [["entity": "workspace", "id": workspace["workspaceId"]!, "revision": 1, "record": workspace]],
                            "startCursor": "complete", "nextCursor": NSNull(),
                        ]))
                    case "changes": return (200, [:], Data(#"{"items":[],"cursor":"complete","highWaterCursor":"complete","hasMore":false}"#.utf8))
                    default: return (404, [:], Data())
                    }
                } catch {
                    Issue.record(error)
                    return (500, [:], Data())
                }
            }
            defer { ImageURLProtocol.remove(origin: connection.origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let api = SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" })
            for _ in 0 ..< (committedBeforeFailure ? 1 : 2) {
                await #expect(throws: (any Error).self) {
                    try await LocalWorkspaceImport.createDestination(
                        sourceId: source.id,
                        organizationId: organization,
                        name: "Server",
                        connection: connection,
                        dbQueue: database.dbQueue,
                        api: api
                    )
                }
            }
            let prepared = try #require(try await database.dbQueue.read { try WorkspaceImportDestinationRecord.fetchOne($0) })
            #expect(prepared.destinationWorkspaceId != source.id)
            // Reopen the actual temporary database: the retry must not rely on process memory.
            let reopened = try AppDatabaseManager(path: path)
            let destination = try await LocalWorkspaceImport.createDestination(
                sourceId: source.id, organizationId: organization, name: "Server", connection: connection, dbQueue: reopened.dbQueue, api: api
            )
            #expect(destination.workspaceId == prepared.destinationWorkspaceId)
            let requests = state.withLock { $0.requests }
            #expect(requests.count == (committedBeforeFailure ? 1 : 2))
            #expect(Set(requests).count == 1)
            try await reopened.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER reject_import BEFORE UPDATE OF workspace_id ON meetings
                BEGIN SELECT RAISE(ABORT, 'injected import failure'); END
                """)
            }
            await #expect(throws: (any Error).self) {
                try await LocalWorkspaceImport.run(
                    sourceId: source.id, destination: destination, dbQueue: reopened.dbQueue,
                    backup: BackupService(dbQueue: reopened.dbQueue, applicationSupportURL: directory), api: api,
                    screenshots: ScreenshotContentProvider()
                )
            }
            try await reopened.dbQueue.write { db in
                #expect(try WorkspaceImportDestinationRecord.fetchOne(db)?.requestJSON == prepared.requestJSON)
                #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.workspaceId == source.id)
                #expect(try LocalWorkspaceImportRecord.fetchCount(db) == 0)
                try db.execute(sql: "DROP TRIGGER reject_import")
            }
            let result = try await LocalWorkspaceImport.run(
                sourceId: source.id, destination: destination, dbQueue: reopened.dbQueue,
                backup: BackupService(dbQueue: reopened.dbQueue, applicationSupportURL: directory), api: api,
                screenshots: ScreenshotContentProvider()
            )
            #expect(result.id == destination.workspaceId)
            try await reopened.dbQueue.read { db in
                let remaining = try #require(try WorkspaceRecord.fetchOne(db, key: source.id))
                #expect(remaining.name == source.name)
                #expect(remaining.accountConnectionId == nil)
                #expect(remaining.generationSettings == source.generationSettings)
                #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.workspaceId == destination.workspaceId)
                #expect(try WorkspaceImportDestinationRecord.fetchCount(db) == 0)
                #expect(try SyncTransactionQueue.hasPending(workspaceId: destination.workspaceId, in: db))
                let imported = try #require(try LocalWorkspaceImportRecord.fetchOne(db))
                #expect(FileManager.default.fileExists(atPath: imported.backupPath))
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }
    }
#endif
