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
        func togglingVectorSearchDoesNotBuildOrDiscardQueuedWork() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let indexer = VectorSearchIndexer(dbQueue: database.dbQueue, embedder: FakeEmbeddingProvider())
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO search_documents(
                        kind, sourceId, vaultId, projectId, sourceContentHash,
                        indexGeneration, updatedAt
                    ) VALUES('project', ?, ?, ?, 'disabled', 1, ?)
                    """,
                    arguments: [UUID.v7(), UUID.v7(), UUID.v7(), Date()]
                )
                #expect(try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'vector'"
                ) == 0)
            }
            try await indexer.setEnabled(true)
            await indexer.drain()
            try await database.dbQueue.write { db in
                #expect(try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'vector'"
                ) == 0)
                try db.execute(
                    sql: """
                    INSERT INTO search_documents(
                        kind, sourceId, vaultId, projectId, sourceContentHash,
                        indexGeneration, updatedAt
                    ) VALUES('project', ?, ?, ?, 'enabled', 1, ?)
                    """,
                    arguments: [UUID.v7(), UUID.v7(), UUID.v7(), Date()]
                )
                let documentID = db.lastInsertedRowID
                #expect(try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'vector'"
                ) == 1)
                try db.execute(
                    sql: """
                    INSERT INTO search_documents_vec(
                        documentId, embedding, sourceContentHash, indexGeneration, updatedAt
                    ) VALUES(?, ?, 'enabled', 1, ?)
                    """,
                    arguments: [documentID, Data(count: 1024), Date()]
                )
                try db.execute(
                    sql: "UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'vector'"
                )
            }
            try await indexer.setEnabled(false)
            try await indexer.setEnabled(true)
            let snapshot = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'vector'"
                    ) ?? 0,
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_vec") ?? 0,
                    String.fetchOne(
                        db,
                        sql: "SELECT phase FROM search_index_state WHERE indexKind = 'vector'"
                    )
                )
            }
            #expect(snapshot == (1, 1, "ready"))
        }

        @Test
        func configurationMismatchWaitsForExplicitRebuild() async throws {
            let fake = FakeEmbeddingProvider()
            let (database, indexer) = try await indexingFixture(count: 1, fake: fake)
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE search_index_state SET phase = 'ready', analyzerConfigurationHash = 'stale'
                    WHERE indexKind = 'vector'
                    """
                )
                try db.execute(
                    sql: "UPDATE search_documents SET sourceContentHash = 'changed' WHERE kind = 'project'"
                )
            }

            await indexer.drain()

            #expect(await fake.batchSizes.isEmpty)
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'vector'")
            } == 1)
        }

        @Test
        func supersededFifthFailureKeepsAndProcessesTheNewGeneration() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let fake = SupersededFailureEmbeddingProvider()
            let indexer = VectorSearchIndexer(dbQueue: database.dbQueue, embedder: fake)
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/vector-generation-vault",
                name: "Vault",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let project = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                parentProjectId: nil,
                name: "Generation project",
                createdAt: .now,
                description: "body",
                projectType: .undefined
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try project.insert(db)
            }
            await database.searchIndexer.drain()
            try await indexer.setEnabled(true)
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'vector'"
                )
                try db.execute(
                    sql: "UPDATE search_documents SET sourceContentHash = 'first' WHERE kind = 'project'"
                )
                try db.execute(
                    sql: "UPDATE search_index_jobs SET attempts = 4 WHERE indexKind = 'vector'"
                )
            }

            let drain = Task { await indexer.drain() }
            #expect(await pollUntil { await fake.didStartFirstBatch })
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE search_documents SET sourceContentHash = 'second' WHERE kind = 'project'"
                )
            }
            await fake.releaseFirstBatch()
            await drain.value

            let snapshot = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'vector'"),
                    String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'vector'"),
                    String.fetchOne(db, sql: "SELECT sourceContentHash FROM search_documents_vec")
                )
            }
            #expect(snapshot == (0, "ready", "second"))
            #expect(await fake.callCount == 2)
        }

        @Test
        func disabledSourceChangeRequiresExplicitRebuildWithoutDiscardingVectors() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let indexer = VectorSearchIndexer(dbQueue: database.dbQueue, embedder: FakeEmbeddingProvider())
            let documentID = try await database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO search_documents(
                        kind, sourceId, vaultId, projectId, sourceContentHash,
                        indexGeneration, updatedAt
                    ) VALUES('project', ?, ?, ?, 'before', 1, ?)
                    """,
                    arguments: [UUID.v7(), UUID.v7(), UUID.v7(), Date()]
                )
                return db.lastInsertedRowID
            }
            try await indexer.setEnabled(true)
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO search_documents_vec(
                        documentId, embedding, sourceContentHash, indexGeneration, updatedAt
                    ) VALUES(?, ?, 'before', 1, ?)
                    """,
                    arguments: [documentID, Data(count: 1024), Date()]
                )
                try db.execute(sql: "DELETE FROM search_index_jobs WHERE indexKind = 'vector'")
                try db.execute(
                    sql: "UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'vector'"
                )
            }

            try await indexer.setEnabled(false)
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE search_documents SET sourceContentHash = 'after' WHERE id = ?",
                    arguments: [documentID]
                )
            }
            try await indexer.setEnabled(true)

            let snapshot = try await database.dbQueue.read { db in
                try (
                    String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'vector'"),
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'vector'"),
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_vec")
                )
            }
            #expect(snapshot == ("pending", 0, 1))
        }

        @Test
        func searchObservationIgnoresVectorProgressAndPublishesReadyTransition() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let initial = try await database.dbQueue.read {
                try SidebarViewModel.searchIndexObservationValues(in: $0)
            }

            try await database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE search_index_state
                    SET isEnabled = 1, phase = 'metadata', indexRevision = indexRevision + 1
                    WHERE indexKind = 'vector'
                    """
                )
            }
            let indexing = try await database.dbQueue.read {
                try SidebarViewModel.searchIndexObservationValues(in: $0)
            }
            #expect(indexing == [initial[0], 1, 0])

            try await database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE search_index_state SET indexRevision = indexRevision + 1
                    WHERE indexKind = 'vector'
                    """
                )
            }
            let progressed = try await database.dbQueue.read {
                try SidebarViewModel.searchIndexObservationValues(in: $0)
            }
            #expect(progressed == indexing)

            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'vector'"
                )
            }
            let ready = try await database.dbQueue.read {
                try SidebarViewModel.searchIndexObservationValues(in: $0)
            }
            #expect(ready[0] != indexing[0])
            #expect(ready[1...] == [1, 1])
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

        @Test
        func truncatesRenormalizesAndEncodes256Dimensions() throws {
            let source = (0 ..< 768).map { Float($0 + 1) }
            let vector = try EmbeddingVector.truncateAndNormalize(source)
            #expect(vector.count == 256)
            #expect(abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 0.000_01)
            let data = try EmbeddingVector.encode(vector)
            #expect(data.count == 1024)
            #expect(try EmbeddingVector.decode(data) == vector)
            #expect(try abs(EmbeddingVector.cosineSimilarity(vector, vector) - 1) < 0.000_01)
            let limited = EmbeddingGemmaDescriptor.limitedTokens(Array(0 ..< 3000))
            #expect(limited.count == 2048)
            #expect(limited.last == 2999)
        }

        @Test
        func batchingUsesFourDocumentsAndPadsWithAttentionMask() {
            #expect(EmbeddingBatchPlanner.batches(for: [[1]]).map(\.sourceIndices.count) == [1])
            #expect(EmbeddingBatchPlanner.batches(for: Array(repeating: [1], count: 4))
                .map(\.sourceIndices.count) == [4])
            #expect(EmbeddingBatchPlanner.batches(for: Array(repeating: [1], count: 5))
                .map(\.sourceIndices.count) == [4, 1])

            let batch = EmbeddingBatchPlanner.batches(for: [[1, 2, 3], [4]], paddingToken: 0)[0]
            #expect(batch.paddedTokens == [[1, 2, 3], [4, 0, 0]])
            #expect(batch.attentionMask == [[1, 1, 1], [1, 0, 0]])
            #expect(EmbeddingBatchPlanner.batches(for: Array(repeating: Array(repeating: 1, count: 1025), count: 4))
                .map(\.sourceIndices.count) == [3, 1])
        }

        @Test
        func detectsBundledMLXMetalLibrary() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let resources = root.appending(path: "Resources")
            let library = resources.appending(path: "mlx-swift_Cmlx.bundle/default.metallib")
            try FileManager.default.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: library)
            defer { try? FileManager.default.removeItem(at: root) }

            #expect(MLXRuntimeResources.hasMetalLibrary(
                bundleURL: root,
                resourceURL: resources,
                executableURL: root.appending(path: "MacOS/Dahlia")
            ))
        }

        @Test
        func pinsEveryRuntimeModelFile() {
            let requiredFiles: Set = [
                "added_tokens.json",
                "config.json",
                "model.safetensors",
                "model.safetensors.index.json",
                "special_tokens_map.json",
                "tokenizer.json",
                "tokenizer.model",
                "tokenizer_config.json",
            ]
            #expect(Set(EmbeddingGemmaDescriptor.fileChecksums.keys) == requiredFiles)
        }

        @Test
        func reciprocalRankFusionRewardsOverlapAndKeepsSemanticOnlyHits() throws {
            let semantic = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
            let lexical = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
            let overlap = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
            let ranked = HybridSearchRRF.rank(
                fullText: [lexical, overlap],
                vector: [semantic, overlap]
            )
            #expect(ranked.first == overlap)
            #expect(ranked.dropFirst().first == lexical)
            #expect(Set(ranked) == [lexical, overlap, semantic])
        }

        @Test
        func indexerCoalescesAndStoresFakeEmbedding() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let fake = FakeEmbeddingProvider()
            let indexer = VectorSearchIndexer(dbQueue: database.dbQueue, embedder: fake)
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/vector-search-vault",
                name: "Vault",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let parent = ProjectRecord(
                id: .v7(), vaultId: vault.id, parentProjectId: nil, name: "Parent",
                createdAt: .now, projectType: .undefined
            )
            let project = ProjectRecord(
                id: .v7(), vaultId: vault.id, parentProjectId: parent.id, name: "Vector project",
                createdAt: .now, description: "semantic body", projectType: nil
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try parent.insert(db)
                try project.insert(db)
                try db.execute(
                    sql: "UPDATE projects SET description = 'semantic body 2' WHERE id = ?",
                    arguments: [project.id]
                )
                #expect(try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM search_index_jobs
                    WHERE indexKind = 'fts' AND targetKind = 'project' AND targetKey = ?
                    """,
                    arguments: [project.id]
                ) == 1)
            }
            await database.searchIndexer.drain()
            try await indexer.setEnabled(true)
            try await indexer.requestRebuild()
            let snapshot = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_vec") ?? 0,
                    Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'vector'"
                    ) ?? 0,
                    Int.fetchOne(
                        db,
                        sql: "SELECT length(embedding) FROM search_documents_vec LIMIT 1"
                    ) ?? 0
                )
            }
            #expect(snapshot == (2, 0, 1024))
            #expect(await fake.batchSizes == [2])
            let input = try #require(await fake.embeddedDocuments.first { $0.title == "Parent/Vector project" })
            #expect(input.text == "semantic body 2")
        }

        @Test
        func indexerBatchesFiveDocumentsAndPreservesResultMapping() async throws {
            let fake = FakeEmbeddingProvider()
            let (database, indexer) = try await indexingFixture(count: 5, fake: fake)
            try await indexer.requestRebuild()

            #expect(await fake.batchSizes == [4, 1])
            let stored = try await database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT projects.name, search_documents_vec.embedding
                    FROM search_documents_vec
                    JOIN search_documents ON search_documents.id = search_documents_vec.documentId
                    JOIN projects ON projects.id = search_documents.sourceId
                    ORDER BY projects.name
                    """
                ).map { row in
                    try (row["name"] as String, EmbeddingVector.decode(row["embedding"] as Data).first)
                }
            }
            #expect(stored.map(\.0) == (0 ..< 5).map { "P\($0)" })
            #expect(stored.map(\.1) == [0, 1, 2, 3, 4])
        }

        @Test
        func partialBatchFailureRetriesOnlyFailedDocument() async throws {
            let fake = FakeEmbeddingProvider(invalidTitles: ["P1"])
            let (database, indexer) = try await indexingFixture(count: 2, fake: fake)

            try await indexer.requestRebuild()

            let snapshot = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_vec") ?? -1,
                    Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'vector' AND status = 'pending'"
                    ) ?? -1
                )
            }
            #expect(snapshot == (1, 1))
            #expect(await fake.batchSizes == [2])
        }

        @Test
        func cancellationDoesNotSaveClaimedBatch() async throws {
            let fake = FakeEmbeddingProvider(blocksUntilCancelled: true)
            let (database, indexer) = try await indexingFixture(count: 1, fake: fake)
            let rebuild = Task { try await indexer.requestRebuild() }
            #expect(await pollUntil { await fake.hasStarted })

            rebuild.cancel()
            _ = try? await rebuild.value

            let snapshot = try database.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT status, attempts, leaseExpiresAt,
                           (SELECT COUNT(*) FROM search_documents_vec) AS vectorCount
                    FROM search_index_jobs WHERE indexKind = 'vector'
                    """
                )
            }
            #expect(snapshot?["vectorCount"] as Int? == 0)
            #expect(snapshot?["status"] as String? == "pending")
            #expect(snapshot?["attempts"] as Int? == 0)
            #expect(snapshot?["leaseExpiresAt"] as Date? == nil)
        }

        @Test
        func stoppingWorkerDuringInferenceDoesNotSaveBatch() async throws {
            let fake = FakeEmbeddingProvider(blocksUntilCancelled: true)
            let (database, indexer) = try await indexingFixture(count: 1, fake: fake)
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE search_index_state SET phase = 'metadata', totalCount = 1
                    WHERE indexKind = 'vector'
                    """
                )
                try db.execute(
                    sql: """
                    INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
                    SELECT 'vector', 'document', id, unixepoch('subsec'), unixepoch('subsec')
                    FROM search_documents
                    """
                )
            }
            await indexer.start()
            #expect(await pollUntil { await fake.hasStarted })

            await indexer.stop()

            let snapshot = try database.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT status, attempts, leaseExpiresAt,
                           (SELECT COUNT(*) FROM search_documents_vec) AS vectorCount
                    FROM search_index_jobs WHERE indexKind = 'vector'
                    """
                )
            }
            #expect(snapshot?["vectorCount"] as Int? == 0)
            #expect(snapshot?["status"] as String? == "pending")
            #expect(snapshot?["attempts"] as Int? == 0)
            #expect(snapshot?["leaseExpiresAt"] as Date? == nil)
        }

        @Test(.timeLimit(.minutes(1)))
        func pausingForRecordingDoesNotAwaitNonCancellableInference() async throws {
            let fake = NonCancellableEmbeddingProvider()
            let (database, indexer) = try await indexingFixture(count: 1, fake: fake)
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE search_index_state SET phase = 'metadata', totalCount = 1
                    WHERE indexKind = 'vector'
                    """
                )
                try db.execute(
                    sql: """
                    INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
                    SELECT 'vector', 'document', id, unixepoch('subsec'), unixepoch('subsec')
                    FROM search_documents
                    """
                )
            }
            await indexer.start()
            #expect(await pollUntil { await fake.hasStarted })

            let completion = CompletionFlag()
            let pause = Task {
                await indexer.pauseForRecording()
                await completion.markCompleted()
            }
            #expect(await pollUntil(timeout: .seconds(1)) { await completion.isCompleted })
            await fake.release()
            await pause.value
            #expect(await pollUntil { await fake.hasFinished })
            let paused = try await database.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT status, (SELECT COUNT(*) FROM search_documents_vec) AS vectorCount
                    FROM search_index_jobs WHERE indexKind = 'vector'
                    """
                )
            }
            #expect(paused?["status"] as String? == "processing")
            #expect(paused?["vectorCount"] as Int? == 0)
            #expect(await fake.callCount == 1)

            await indexer.start()
            #expect(await pollUntil {
                let vectorCount = try? await database.dbQueue.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_vec")
                }
                return vectorCount == 1
            })
            #expect(await fake.callCount == 2)
            await indexer.stop()
        }

        @Test
        func realModelSingletonAndPaddedBatchEmbeddingsAreClose() async throws {
            guard let basePath = ProcessInfo.processInfo.environment["DAHLIA_EMBEDDING_TEST_BASE"] else { return }
            let service = EmbeddingGemmaService(
                baseDirectory: URL(fileURLWithPath: basePath),
                validatesRuntimeResources: false
            )
            let document = DocumentEmbeddingInput(title: "Batch compatibility", text: "same document")
            let singleton = try await service.documentEmbeddings([document])[0]
            let batched = try await service.documentEmbeddings([
                document,
                DocumentEmbeddingInput(title: "Padding", text: String(repeating: "longer text ", count: 100)),
            ])[0]

            let similarity = try EmbeddingVector.cosineSimilarity(singleton, batched)
            print("EmbeddingGemma singleton/batch cosine: \(similarity)")
            #expect(similarity > 0.999)
        }

        @Test
        func emptyMeetingRemovesStaleEmbedding() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let indexer = VectorSearchIndexer(dbQueue: database.dbQueue, embedder: FakeEmbeddingProvider())
            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/empty-vector-search-vault",
                name: "Vault",
                createdAt: .now,
                lastOpenedAt: .now
            )
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: nil,
                name: "   ",
                description: "\n",
                createdAt: .now,
                updatedAt: .now
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
            }
            await database.searchIndexer.drain()
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO search_documents_vec(
                        documentId, embedding, sourceContentHash, indexGeneration, updatedAt
                    ) SELECT id, ?, sourceContentHash, 1, ? FROM search_documents WHERE meetingId = ?
                    """,
                    arguments: [Data(count: 1024), Date(), meeting.id]
                )
            }

            try await indexer.setEnabled(true)
            try await indexer.requestRebuild()

            let snapshot = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_vec") ?? -1,
                    Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'vector'"
                    ) ?? -1
                )
            }
            #expect(snapshot == (0, 0))
        }

        @Test
        func emptyProjectDescriptionStillEmbedsProjectPath() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let fake = FakeEmbeddingProvider()
            let indexer = VectorSearchIndexer(dbQueue: database.dbQueue, embedder: fake)
            let vault = VaultRecord(
                id: .v7(), path: "/tmp/empty-project-vector-vault", name: "Vault",
                createdAt: .now, lastOpenedAt: .now
            )
            let project = ProjectRecord(
                id: .v7(), vaultId: vault.id, parentProjectId: nil, name: "Project name",
                createdAt: .now, description: "   \n", projectType: .undefined
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try project.insert(db)
            }
            await database.searchIndexer.drain()
            try await indexer.setEnabled(true)
            try await indexer.requestRebuild()

            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_vec")
            } == 1)
            let input = try #require(await fake.embeddedDocuments.first)
            #expect(input.title == "Project name")
            #expect(input.text.isEmpty)
        }

        @Test
        func projectDescriptionChangeQueuesOnlyTheProjectVector() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let indexer = VectorSearchIndexer(dbQueue: database.dbQueue, embedder: FakeEmbeddingProvider())
            let vault = VaultRecord(
                id: .v7(), path: "/tmp/project-vector-propagation-vault", name: "Vault",
                createdAt: .now, lastOpenedAt: .now
            )
            let project = ProjectRecord(
                id: .v7(), vaultId: vault.id, parentProjectId: nil, name: "Project",
                createdAt: .now, description: "Before", projectType: .undefined
            )
            let meeting = MeetingRecord(
                id: .v7(), vaultId: vault.id, projectId: project.id, name: "Meeting",
                createdAt: .now, updatedAt: .now
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try project.insert(db)
                try meeting.insert(db)
                try SummaryRecord(
                    meetingId: meeting.id,
                    title: "Summary",
                    document: Self.summaryDocument(body: String(repeating: "会", count: 80)).databaseJSONString(),
                    createdAt: .now
                ).insert(db)
            }
            await database.searchIndexer.drain()
            try await indexer.setEnabled(true)
            try await indexer.requestRebuild()

            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE projects SET description = ? WHERE id = ?",
                    arguments: ["After", project.id]
                )
            }
            await database.searchIndexer.drain()

            let queuedKinds = try await database.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT search_documents.kind FROM search_index_jobs
                    JOIN search_documents ON search_documents.id = search_index_jobs.targetKey
                    WHERE search_index_jobs.indexKind = 'vector'
                    ORDER BY search_documents.kind
                    """
                )
            }
            #expect(queuedKinds == ["project"])

            await indexer.drain()
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE meetings SET description = ? WHERE id = ?",
                    arguments: ["Excluded", meeting.id]
                )
                try db.execute(
                    sql: "UPDATE projects SET name = ? WHERE id = ?",
                    arguments: ["Renamed", project.id]
                )
            }
            await database.searchIndexer.drain()

            let hierarchyKinds = try await database.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: """
                    SELECT search_documents.kind FROM search_index_jobs
                    JOIN search_documents ON search_documents.id = search_index_jobs.targetKey
                    WHERE search_index_jobs.indexKind = 'vector'
                    ORDER BY search_documents.kind
                    """
                )
            }
            #expect(hierarchyKinds == ["project"])
        }

        @Test
        func meetingRequiresNonemptySummaryContentForEmbedding() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let fake = FakeEmbeddingProvider()
            let indexer = VectorSearchIndexer(dbQueue: database.dbQueue, embedder: fake)
            let vault = VaultRecord(
                id: .v7(), path: "/tmp/vector-body-vault", name: "Vault",
                createdAt: .now, lastOpenedAt: .now
            )
            let project = ProjectRecord(
                id: .v7(), vaultId: vault.id, parentProjectId: nil, name: "Metadata project",
                createdAt: .now, projectType: .undefined
            )
            let shortSummary = MeetingRecord(
                id: .v7(), vaultId: vault.id, projectId: project.id, name: "Short summary",
                description: String(repeating: "除外", count: 40), createdAt: .now, updatedAt: .now
            )
            let detailedSummary = MeetingRecord(
                id: .v7(), vaultId: vault.id, projectId: project.id, name: "Detailed summary",
                description: String(repeating: "除外", count: 40),
                createdAt: .now, updatedAt: .now
            )
            let metadataOnly = MeetingRecord(
                id: .v7(), vaultId: vault.id, projectId: project.id, name: "Metadata title",
                createdAt: .now, updatedAt: .now
            )
            let emptySummary = MeetingRecord(
                id: .v7(), vaultId: vault.id, projectId: project.id, name: "Empty summary",
                createdAt: .now, updatedAt: .now
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try project.insert(db)
                try shortSummary.insert(db)
                try detailedSummary.insert(db)
                try SummaryRecord(
                    meetingId: shortSummary.id,
                    title: "Summary",
                    document: Self.summaryDocument(body: "あ").databaseJSONString(),
                    createdAt: .now
                ).insert(db)
                try SummaryRecord(
                    meetingId: detailedSummary.id,
                    title: "Summary",
                    document: Self.summaryDocument(
                        body: String(repeating: "い", count: 40),
                        description: String(repeating: "う", count: 40)
                    ).databaseJSONString(),
                    createdAt: .now
                ).insert(db)
                try metadataOnly.insert(db)
                try emptySummary.insert(db)
                try SummaryRecord(
                    meetingId: emptySummary.id,
                    title: "Summary",
                    document: Self.summaryDocument(body: " \n", description: " ").databaseJSONString(),
                    createdAt: .now
                ).insert(db)
            }
            await database.searchIndexer.drain()
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO search_documents_vec(
                        documentId, embedding, sourceContentHash, indexGeneration, updatedAt
                    ) SELECT id, ?, sourceContentHash, 1, ? FROM search_documents WHERE meetingId = ?
                    """,
                    arguments: [Data(count: 1024), Date(), metadataOnly.id]
                )
            }

            try await indexer.setEnabled(true)
            try await indexer.requestRebuild()

            let embeddedMeetingIDs = try await database.dbQueue.read { db in
                try UUID.fetchAll(
                    db,
                    sql: """
                    SELECT search_documents.meetingId FROM search_documents_vec
                    JOIN search_documents ON search_documents.id = search_documents_vec.documentId
                    WHERE search_documents.kind = 'meeting'
                    """
                )
            }
            #expect(Set(embeddedMeetingIDs) == [shortSummary.id, detailedSummary.id])
            let embeddedTitles = await fake.embeddedTitles
            #expect(embeddedTitles.contains("Short summary"))
            #expect(embeddedTitles.contains("Detailed summary"))
            #expect(!embeddedTitles.contains("Metadata title"))
            #expect(!embeddedTitles.contains("Empty summary"))
            let shortDocument = try #require(await fake.embeddedDocuments.first { $0.title == "Short summary" })
            #expect(shortDocument.text == "あ")
            let embeddedDocument = try #require(await fake.embeddedDocuments.first { $0.title == "Detailed summary" })
            #expect(embeddedDocument.text == String(repeating: "う", count: 40) + "\n" + String(repeating: "い", count: 40))
            #expect(!embeddedDocument.text.contains("除外"))
        }

        private nonisolated static func summaryDocument(body: String, description: String = "") -> SummaryDocument {
            SummaryDocument(
                title: "Summary",
                description: description,
                sections: [SummarySection(id: .v7(), heading: "", blocks: [.paragraph(body)])]
            )
        }

        private func indexingFixture(
            count: Int,
            fake: any TextEmbeddingProviding
        ) async throws -> (AppDatabaseManager, VectorSearchIndexer) {
            let database = try AppDatabaseManager(path: ":memory:")
            let indexer = VectorSearchIndexer(dbQueue: database.dbQueue, embedder: fake)
            let vault = VaultRecord(
                id: .v7(), path: "/tmp/vector-fixture-\(UUID.v7())", name: "Vault",
                createdAt: .now, lastOpenedAt: .now
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
                for index in 0 ..< count {
                    try ProjectRecord(
                        id: .v7(), vaultId: vault.id, parentProjectId: nil, name: "P\(index)",
                        createdAt: .now, description: "P\(index)", projectType: .undefined
                    ).insert(db)
                }
            }
            await database.searchIndexer.drain()
            try await indexer.setEnabled(true)
            return (database, indexer)
        }
    }

    private actor FakeEmbeddingProvider: TextEmbeddingProviding {
        private let invalidTitles: Set<String>
        private let blocksUntilCancelled: Bool
        private(set) var batchSizes: [Int] = []
        private(set) var embeddedTitles: [String] = []
        private(set) var embeddedDocuments: [DocumentEmbeddingInput] = []
        private(set) var hasStarted = false
        var isAvailable: Bool { true }

        init(invalidTitles: Set<String> = [], blocksUntilCancelled: Bool = false) {
            self.invalidTitles = invalidTitles
            self.blocksUntilCancelled = blocksUntilCancelled
        }

        func queryEmbedding(_: String) -> [Float] {
            vector
        }

        func documentEmbeddings(_ documents: [DocumentEmbeddingInput]) async throws -> [[Float]] {
            batchSizes.append(documents.count)
            embeddedTitles.append(contentsOf: documents.map(\.title))
            embeddedDocuments.append(contentsOf: documents)
            hasStarted = true
            while blocksUntilCancelled {
                try await Task.sleep(for: .milliseconds(10))
            }
            return documents.map { document in
                let identifier = document.title.isEmpty ? document.text : document.title
                if invalidTitles.contains(identifier) {
                    return Array(repeating: 0, count: EmbeddingGemmaDescriptor.dimensions - 1)
                }
                let value = Float(identifier.dropFirst()) ?? 1
                return [value] + Array(repeating: 0, count: EmbeddingGemmaDescriptor.dimensions - 1)
            }
        }

        private var vector: [Float] {
            [1] + Array(repeating: 0, count: EmbeddingGemmaDescriptor.dimensions - 1)
        }
    }

    private actor SupersededFailureEmbeddingProvider: TextEmbeddingProviding {
        private var releasesFirstBatch = false
        private(set) var didStartFirstBatch = false
        private(set) var callCount = 0
        var isAvailable: Bool { true }

        func queryEmbedding(_: String) -> [Float] {
            vector
        }

        func documentEmbeddings(_ documents: [DocumentEmbeddingInput]) async throws -> [[Float]] {
            callCount += 1
            if callCount == 1 {
                didStartFirstBatch = true
                while !releasesFirstBatch {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return documents.map { _ in Array(repeating: 0, count: EmbeddingGemmaDescriptor.dimensions - 1) }
            }
            return documents.map { _ in vector }
        }

        func releaseFirstBatch() {
            releasesFirstBatch = true
        }

        private var vector: [Float] {
            [1] + Array(repeating: 0, count: EmbeddingGemmaDescriptor.dimensions - 1)
        }
    }

    private actor NonCancellableEmbeddingProvider: TextEmbeddingProviding {
        private var isReleased = false
        private(set) var hasStarted = false
        private(set) var hasFinished = false
        private(set) var callCount = 0
        var isAvailable: Bool { true }

        func queryEmbedding(_: String) -> [Float] {
            vector
        }

        func documentEmbeddings(_ documents: [DocumentEmbeddingInput]) async -> [[Float]] {
            callCount += 1
            hasStarted = true
            while !isReleased {
                try? await Task.sleep(for: .milliseconds(10))
            }
            hasFinished = true
            return documents.map { _ in vector }
        }

        func release() {
            isReleased = true
        }

        private var vector: [Float] {
            [1] + Array(repeating: 0, count: EmbeddingGemmaDescriptor.dimensions - 1)
        }
    }

    private actor CompletionFlag {
        private(set) var isCompleted = false

        func markCompleted() {
            isCompleted = true
        }
    }
#endif
