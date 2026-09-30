#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct DocumentCoreWorkerTests {
        @Test func literalImportAndReopen() async throws {
            let worker = DocumentCoreWorker()
            defer { worker.stop() }
            let legacy = "# literal\r\n\n日本語\n"
            let imported = try await worker.process(DocumentCoreCommand(text: legacy, repair: true))
            #expect(imported.projection.text == legacy)
            #expect(imported.projection.blocks.count == 4)
            let reopened = try await worker.process(DocumentCoreCommand(checkpoint: imported.checkpoint))
            #expect(reopened.projection.text == legacy)
            #expect(reopened.vector == imported.vector)
        }

        @Test func duplicateUpdateDoesNotDuplicateText() async throws {
            let worker = DocumentCoreWorker()
            defer { worker.stop() }
            let seed = try await worker.process(DocumentCoreCommand(text: "memo"))
            let replayed = try await worker.process(DocumentCoreCommand(updates: [seed.update, seed.update]))
            #expect(replayed.projection.text == "memo")
            #expect(replayed.projection.blocks == seed.projection.blocks)
        }

        @Test func sharedRuntimeFixture() async throws {
            struct Fixture: Decodable { let checkpoint: String
                let updates: [String]
                let text: String
                let blocks: [DocumentBlock]
            }
            let url = try #require(Bundle.module.url(forResource: "documents", withExtension: "json", subdirectory: "Fixtures"))
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
            let worker = DocumentCoreWorker()
            defer { worker.stop() }
            let result = try await worker.process(DocumentCoreCommand(checkpoint: fixture.checkpoint, updates: fixture.updates))
            #expect(result.projection.text == fixture.text)
            #expect(result.projection.blocks == fixture.blocks)
        }

        @Test func documentMigrationPreservesLegacyNotes() throws {
            let queue = try DatabaseQueue()
            try queue.write { db in
                try db
                    .execute(
                        sql: """
                        CREATE TABLE workspaces (id TEXT PRIMARY KEY);
                        CREATE TABLE meetings (id TEXT PRIMARY KEY, workspace_id TEXT);
                        CREATE TABLE notes (meetingId TEXT PRIMARY KEY REFERENCES meetings(id), text TEXT);
                        """
                    )
                let id = UUID.v7()
                try db.execute(sql: "INSERT INTO meetings(id) VALUES (?); INSERT INTO notes VALUES (?, ?)", arguments: [id, id, "private legacy"])
                try DocumentsMigration.migrate(in: db)
                #expect(try String.fetchOne(db, sql: "SELECT text FROM notes") == "private legacy")
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM documents") == 0)
                #expect(try db.tableExists("document_private_copies"))
            }
        }
    }

#endif
