import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct VectorSearchTests {
        @Test
        func migrationPreservesDocumentsAndDefaultsVectorSearchOff() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v36_summarySearch")
            let documentID = try queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO search_documents(
                        kind, sourceId, vaultId, projectId, sourceContentHash,
                        indexGeneration, updatedAt
                    ) VALUES('project', ?, ?, ?, 'hash', 1, ?)
                    """,
                    arguments: [UUID.v7(), UUID.v7(), UUID.v7(), Date()]
                )
                return db.lastInsertedRowID
            }

            try AppDatabaseManager.migrator.migrate(queue)

            try queue.read { db in
                let hasTable = try db.tableExists("search_documents_vec")
                let documentCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents")
                let jobCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'vector'"
                )
                let isEnabled = try Bool.fetchOne(
                    db,
                    sql: "SELECT isEnabled FROM search_index_state WHERE indexKind = 'vector'"
                )
                #expect(hasTable)
                #expect(documentCount == 1)
                #expect(jobCount == 0)
                #expect(isEnabled == false)
                #expect(throws: DatabaseError.self) {
                    try db.execute(
                        sql: """
                        INSERT INTO search_documents_vec(
                            documentId, embedding, sourceContentHash, indexGeneration, updatedAt
                        ) VALUES(?, ?, 'hash', 1, ?)
                        """,
                        arguments: [documentID, Data(count: 1023), Date()]
                    )
                }
            }
        }

        @Test
        func vectorRowIsOneToOneAndCascades() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            try database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO search_documents(
                        kind, sourceId, vaultId, projectId, sourceContentHash,
                        indexGeneration, updatedAt
                    ) VALUES('project', ?, ?, ?, 'hash', 1, ?)
                    """,
                    arguments: [UUID.v7(), UUID.v7(), UUID.v7(), Date()]
                )
                let id = db.lastInsertedRowID
                let data = Data(count: 1024)
                try db.execute(
                    sql: """
                    INSERT INTO search_documents_vec(
                        documentId, embedding, sourceContentHash, indexGeneration, updatedAt
                    ) VALUES(?, ?, 'hash', 1, ?)
                    """,
                    arguments: [id, data, Date()]
                )
                #expect(throws: DatabaseError.self) {
                    try db.execute(
                        sql: """
                        INSERT INTO search_documents_vec(
                            documentId, embedding, sourceContentHash, indexGeneration, updatedAt
                        ) VALUES(?, ?, 'hash', 1, ?)
                        """,
                        arguments: [id, data, Date()]
                    )
                }
                try db.execute(sql: "DELETE FROM search_documents WHERE id = ?", arguments: [id])
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_vec") == 0)
            }
        }

    }
#endif
