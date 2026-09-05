import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct RetireVectorSearchTests {
        @Test
        func upgradePreservesVectorsAndJobsButStopsEnqueueing() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v43_syncRecovery")
            let documentID = try queue.write { db in
                try db.execute(sql: "UPDATE search_index_state SET isEnabled = 1 WHERE indexKind = 'vector'")
                try db.execute(
                    sql: """
                    INSERT INTO search_documents(kind, sourceId, vaultId, projectId,
                        sourceContentHash, indexGeneration, updatedAt)
                    VALUES('project', ?, ?, ?, 'original', 1, ?)
                    """,
                    arguments: [UUID.v7(), UUID.v7(), UUID.v7(), Date()]
                )
                let id = db.lastInsertedRowID
                try db.execute(
                    sql: """
                    INSERT INTO search_documents_vec(documentId, embedding, sourceContentHash, indexGeneration, updatedAt)
                    VALUES(?, ?, 'original', 1, ?)
                    """,
                    arguments: [id, Data(repeating: 7, count: 1024), Date()]
                )
                return id
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.write { db in
                #expect(try Bool.fetchOne(db, sql: "SELECT isEnabled FROM search_index_state WHERE indexKind = 'vector'") == false)
                #expect(try Data.fetchOne(db, sql: "SELECT embedding FROM search_documents_vec") == Data(repeating: 7, count: 1024))
                #expect(try String.fetchOne(db, sql: "SELECT sourceContentHash FROM search_documents_vec") == "original")
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'vector'") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT generation FROM search_index_jobs WHERE indexKind = 'vector'") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE '%vector%'") == 0)
                try db.execute(sql: "UPDATE search_documents SET sourceContentHash = 'changed' WHERE id = ?", arguments: [documentID])
                try db.execute(
                    sql: """
                    INSERT INTO search_documents(kind, sourceId, vaultId, projectId, sourceContentHash, indexGeneration, updatedAt)
                    VALUES('project', ?, ?, ?, 'new', 1, ?)
                    """,
                    arguments: [UUID.v7(), UUID.v7(), UUID.v7(), Date()]
                )
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'vector'") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT generation FROM search_index_jobs WHERE indexKind = 'vector'") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents") == 2)
            }
        }

        @Test
        func freshDatabaseRetainsSchemaWithoutVectorTriggers() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            try database.dbQueue.read { db in
                let hasVectorTable = try db.tableExists("search_documents_vec")
                #expect(hasVectorTable)
                #expect(try Bool.fetchOne(db, sql: "SELECT isEnabled FROM search_index_state WHERE indexKind = 'vector'") == false)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE '%vector%'") == 0)
            }
        }

        @Test
        func modelCleanupOnlyRemovesGemmaAndCanRepeat() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID.v7().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let gemma = root.appending(path: "Models/EmbeddingGemma/revision")
            let sibling = root.appending(path: "Models/OtherModel")
            try FileManager.default.createDirectory(at: gemma, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            try Data([1]).write(to: gemma.appending(path: "model.safetensors"))
            let database = root.appending(path: "dahlia.sqlite")
            try Data([2]).write(to: database)
            try RetiredEmbeddingModelCleanup.remove(from: root)
            try RetiredEmbeddingModelCleanup.remove(from: root)
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Models/EmbeddingGemma").path))
            #expect(FileManager.default.fileExists(atPath: sibling.path))
            #expect(try Data(contentsOf: database) == Data([2]))
        }
    }
#endif
