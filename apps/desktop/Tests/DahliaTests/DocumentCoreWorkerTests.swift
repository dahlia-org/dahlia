#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct DocumentCoreWorkerTests {
        @Test func rejectsOldSchemaAndUnresolvedDeltas() async throws {
            struct Fixture: Decodable {
                struct LegacySchema: Decodable { let checkpoint: String
                    let append: String
                    let deletion: String
                }

                let v1: LegacySchema
            }
            let url = try #require(Bundle.module.url(forResource: "documents", withExtension: "json", subdirectory: "Fixtures"))
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
            let worker = DocumentCoreWorker()
            defer { worker.stop() }
            await #expect(throws: DocumentCoreError.unsupportedSchema) {
                try await worker.process(DocumentCoreCommand(checkpoint: fixture.v1.checkpoint))
            }
            for update in [fixture.v1.append, fixture.v1.deletion] {
                await #expect(throws: DocumentCoreError.failed) {
                    try await worker.process(DocumentCoreCommand(updates: [update]))
                }
            }
        }

        @Test func purgesExpiredBodiesWithoutChangingVisibleText() async throws {
            struct Fixture: Decodable { let deletionUpdate: String }
            let url = try #require(Bundle.module.url(forResource: "documents", withExtension: "json", subdirectory: "Fixtures"))
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
            let worker = DocumentCoreWorker()
            defer { worker.stop() }
            let retained = try await worker.process(DocumentCoreCommand(checkpoint: fixture.deletionUpdate, purgeBefore: -1))
            let purged = try await worker.process(DocumentCoreCommand(checkpoint: retained.checkpoint, purgeBefore: 1))
            #expect(retained.purged == false)
            #expect(purged.purged == true)
            #expect(purged.projection.text == retained.projection.text)
            #expect(purged.checkpoint != retained.checkpoint)
        }

        @Test func groupsLargeLiteralImportsWithoutChangingLineEndings() async throws {
            let worker = DocumentCoreWorker()
            defer { worker.stop() }
            let text = String(repeating: "a\r\n", count: 6000)
            let result = try await worker.process(DocumentCoreCommand(text: text))
            #expect(result.projection.text == text)
            #expect(result.projection.blocks.count <= 5000)
        }

        @Test func literalImportAndReopen() async throws {
            let worker = DocumentCoreWorker()
            defer { worker.stop() }
            let legacy = "# literal\r\n\n日本語\n"
            let imported = try await worker.process(DocumentCoreCommand(text: legacy))
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
