import DahliaMeetingAccess
import Dispatch
import Foundation
import GRDB
import OSLog

actor VectorSearchIndexer {
    private static let logger = Logger(subsystem: "com.dahlia", category: "VectorIndexing")

    private let dbQueue: DatabaseQueue
    private let embedder: any TextEmbeddingProviding
    private let observationQueue = DispatchQueue(label: "app.dahlia.vector-indexer", qos: .utility)
    private var workerTask: Task<Void, Never>?
    private var observationDrainTask: Task<Void, Never>?
    private var retiredTasks: [Task<Void, Never>] = []
    private var observationDrainGeneration = 0
    private var observation: AnyDatabaseCancellable?
    private var isDraining = false
    private var isPaused = false

    init(dbQueue: DatabaseQueue, embedder: any TextEmbeddingProviding) {
        self.dbQueue = dbQueue
        self.embedder = embedder
    }

    func start() {
        guard workerTask == nil else { return }
        isPaused = false
        observation = ValueObservation.tracking { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) + COALESCE(SUM(generation), 0)
                FROM search_index_jobs WHERE indexKind = 'vector'
                """
            ) ?? 0
        }.removeDuplicates().start(
            in: dbQueue,
            scheduling: .async(onQueue: observationQueue),
            onError: { _ in },
            onChange: { [weak self] _ in
                Task { await self?.scheduleObservationDrain() }
            }
        )
        workerTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.drain()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() async {
        pauseForRecording()
        let tasks = retiredTasks
        retiredTasks.removeAll()
        for task in tasks {
            await task.value
        }
        while isDraining {
            await Task.yield()
        }
    }

    func pauseForRecording() {
        isPaused = true
        let tasks = [workerTask, observationDrainTask].compactMap(\.self)
        tasks.forEach { $0.cancel() }
        retiredTasks.append(contentsOf: tasks)
        workerTask = nil
        observationDrainTask = nil
        observationDrainGeneration &+= 1
        observation?.cancel()
        observation = nil
    }

    func requestRebuild() async throws {
        let isEnabled = try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE search_index_state
                SET indexGeneration = indexGeneration + 1, phase = 'pending',
                    completedCount = 0, totalCount = 0, lastErrorCode = NULL, updatedAt = ?
                WHERE indexKind = 'vector' AND isEnabled = 1
                """,
                arguments: [Date()]
            )
            return db.changesCount > 0
        }
        guard isEnabled else { return }
        try await prepareRebuildIfNeeded()
        await drain()
    }

    func setEnabled(_ isEnabled: Bool) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE search_index_state
                SET isEnabled = ?, updatedAt = ?
                WHERE indexKind = 'vector'
                """,
                arguments: [isEnabled, Date()]
            )
        }
    }

    func drain() async {
        guard !isDraining, !isPaused, await canDrain(), await embedder.isAvailable else { return }
        isDraining = true
        defer { isDraining = false }
        do {
            while !isPaused {
                let jobs = try await claimNextJobs()
                guard !jobs.isEmpty else { break }
                do {
                    try Task.checkCancellation()
                    try await process(jobs)
                } catch is CancellationError {
                    try? await release(jobs)
                    return
                } catch {
                    try await fail(jobs, error: error)
                }
            }
            try await markReadyIfComplete()
        } catch is CancellationError {
        } catch {
            try? await recordFailure(error)
        }
    }

    private func scheduleObservationDrain() {
        guard observationDrainTask == nil else { return }
        observationDrainGeneration &+= 1
        let generation = observationDrainGeneration
        observationDrainTask = Task { [weak self] in
            await self?.runObservationDrain(generation: generation)
        }
    }

    private func runObservationDrain(generation: Int) async {
        await drain()
        if generation == observationDrainGeneration {
            observationDrainTask = nil
        }
    }

    private func prepareRebuildIfNeeded() async throws {
        try await dbQueue.write { db in
            guard let state = try Row.fetchOne(
                db,
                sql: "SELECT * FROM search_index_state WHERE indexKind = 'vector'"
            ) else { return }
            guard state["isEnabled"] as Bool else { return }
            let hash: String = state["analyzerConfigurationHash"]
            var generation: Int = state["indexGeneration"]
            var phase: String = state["phase"]
            guard phase != "failed" else { return }
            if hash != EmbeddingGemmaDescriptor.configurationHash {
                generation += 1
                phase = "pending"
                try db.execute(
                    sql: """
                    UPDATE search_index_state SET analyzerVersion = ?, analyzerConfigurationHash = ?,
                        indexGeneration = ?, phase = 'pending', completedCount = 0,
                        totalCount = 0, lastErrorCode = NULL, updatedAt = ?
                    WHERE indexKind = 'vector'
                    """,
                    arguments: [
                        EmbeddingGemmaDescriptor.modelIdentifier,
                        EmbeddingGemmaDescriptor.configurationHash,
                        generation,
                        Date(),
                    ]
                )
            }
            guard phase != "ready" else { return }
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents") ?? 0
            try db.execute(
                sql: """
                INSERT INTO search_index_jobs(indexKind, targetKind, targetKey, availableAt, updatedAt)
                SELECT 'vector', 'document', id, unixepoch('subsec'), unixepoch('subsec')
                FROM search_documents
                WHERE true
                ON CONFLICT(indexKind, targetKind, targetKey) DO UPDATE SET
                    generation = generation + 1, status = 'pending', attempts = 0,
                    availableAt = excluded.availableAt, claimedAt = NULL, leaseExpiresAt = NULL,
                    lastErrorCode = NULL, updatedAt = excluded.updatedAt
                """
            )
            try db.execute(
                sql: """
                UPDATE search_index_state SET phase = 'metadata', totalCount = ?, completedCount = 0,
                    lastErrorCode = NULL, updatedAt = ? WHERE indexKind = 'vector'
                """,
                arguments: [total, Date()]
            )
        }
    }

    private func claimNextJobs() async throws -> [VectorSearchJob] {
        try await dbQueue.write { db in
            let now = Date()
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT targetKey, generation, attempts FROM search_index_jobs
                WHERE indexKind = 'vector' AND targetKind = 'document' AND availableAt <= ?
                  AND (status = 'pending' OR leaseExpiresAt < ?)
                  AND (SELECT isEnabled FROM search_index_state WHERE indexKind = 'vector') = 1
                ORDER BY priority DESC, availableAt, targetKey LIMIT ?
                """,
                arguments: [now, now, EmbeddingBatchPlanner.maximumDocuments]
            )
            return try rows.map { row in
                let job = VectorSearchJob(
                    documentID: row["targetKey"],
                    generation: row["generation"],
                    attempts: (row["attempts"] as Int) + 1
                )
                try db.execute(
                    sql: """
                    UPDATE search_index_jobs SET status = 'processing', attempts = attempts + 1,
                        claimedAt = ?, leaseExpiresAt = ?, updatedAt = ?
                    WHERE indexKind = 'vector' AND targetKind = 'document'
                      AND targetKey = ? AND generation = ?
                    """,
                    arguments: [
                        now, now.addingTimeInterval(120), now, job.documentID, job.generation,
                    ]
                )
                return job
            }
        }
    }

    private func process(_ jobs: [VectorSearchJob]) async throws {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let documents = try await dbQueue.read { db in
            try jobs.map { job in
                try (job: job, document: VectorDocument.fetch(id: job.documentID, in: db))
            }
        }
        let present = documents.compactMap { item in
            item.document.map { (job: item.job, document: $0) }
        }
        let values = try await embedder.documentEmbeddings(present.map {
            DocumentEmbeddingInput(title: $0.document.title, text: $0.document.text)
        })
        guard values.count == present.count else {
            throw VectorSearchIndexError.resultCountMismatch
        }
        var completed = documents.compactMap { $0.document == nil ? $0.job : nil }
        var encoded: [(job: VectorSearchJob, document: VectorDocument, data: Data)] = []
        var failures: [VectorSearchFailure] = []
        for (index, item) in present.enumerated() {
            do {
                try encoded.append((item.job, item.document, EmbeddingVector.encode(values[index])))
                completed.append(item.job)
            } catch {
                failures.append(VectorSearchFailure(job: item.job, errorCode: errorCode(error)))
            }
        }
        try Task.checkCancellation()
        guard !isPaused else { throw CancellationError() }
        let saveStartedAt = clock.now
        try await save(documents: documents, embeddings: encoded, completedJobs: completed)
        let saveDuration = saveStartedAt.duration(to: clock.now)
        let batchDuration = startedAt.duration(to: clock.now)
        Self.logger.debug(
            "Vector batch documents=\(jobs.count, privacy: .public) db_save_ms=\(saveDuration.milliseconds, privacy: .public) batch_ms=\(batchDuration.milliseconds, privacy: .public) per_document_ms=\(batchDuration.milliseconds / Double(jobs.count), privacy: .public)"
        )
        if !failures.isEmpty {
            try await fail(failures)
        }
    }

    private func save(
        documents: [(job: VectorSearchJob, document: VectorDocument?)],
        embeddings: [(job: VectorSearchJob, document: VectorDocument, data: Data)],
        completedJobs: [VectorSearchJob]
    ) async throws {
        try await dbQueue.write { db in
            let generation = try Int.fetchOne(
                db,
                sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'vector'"
            ) ?? 1
            let now = Date()
            for (job, document, data) in embeddings {
                try db.execute(
                    sql: """
                    INSERT INTO search_documents_vec(
                        documentId, embedding, sourceContentHash, indexGeneration, updatedAt
                    ) SELECT id, ?, sourceContentHash, ?, ? FROM search_documents
                    WHERE id = ? AND sourceContentHash = ?
                    ON CONFLICT(documentId) DO UPDATE SET embedding = excluded.embedding,
                        sourceContentHash = excluded.sourceContentHash,
                        indexGeneration = excluded.indexGeneration, updatedAt = excluded.updatedAt
                    """,
                    arguments: [data, generation, now, job.documentID, document.sourceContentHash]
                )
            }
            for item in documents where item.document == nil {
                try db.execute(
                    sql: "DELETE FROM search_documents_vec WHERE documentId = ?",
                    arguments: [item.job.documentID]
                )
            }
            var completedCount = 0
            for job in completedJobs {
                try db.execute(
                    sql: """
                    DELETE FROM search_index_jobs WHERE indexKind = 'vector' AND targetKind = 'document'
                      AND targetKey = ? AND generation = ?
                    """,
                    arguments: [job.documentID, job.generation]
                )
                completedCount += db.changesCount
            }
            if completedCount > 0 {
                try db.execute(
                    sql: """
                    UPDATE search_index_state SET completedCount = min(totalCount, completedCount + ?),
                        updatedAt = ? WHERE indexKind = 'vector'
                    """,
                    arguments: [completedCount, now]
                )
            }
        }
    }

    private func fail(_ jobs: [VectorSearchJob], error: Error) async throws {
        let code = errorCode(error)
        try await fail(jobs.map { VectorSearchFailure(job: $0, errorCode: code) })
    }

    private func release(_ jobs: [VectorSearchJob]) async throws {
        try await Task.detached(priority: .utility) { [dbQueue] in
            try await dbQueue.write { db in
                for job in jobs {
                    try db.execute(
                        sql: """
                        UPDATE search_index_jobs
                        SET status = 'pending', attempts = max(0, attempts - 1), availableAt = ?,
                            claimedAt = NULL, leaseExpiresAt = NULL, updatedAt = ?
                        WHERE indexKind = 'vector' AND targetKind = 'document'
                          AND targetKey = ? AND generation = ? AND status = 'processing'
                        """,
                        arguments: [Date(), Date(), job.documentID, job.generation]
                    )
                }
            }
        }.value
    }

    private func fail(_ failures: [VectorSearchFailure]) async throws {
        let reachedRetryLimit = try await dbQueue.write { db in
            var reachedRetryLimit = false
            for failure in failures {
                let job = failure.job
                if job.attempts >= 5 {
                    try db.execute(
                        sql: """
                        DELETE FROM search_index_jobs WHERE indexKind = 'vector' AND targetKind = 'document'
                          AND targetKey = ? AND generation = ?
                        """,
                        arguments: [job.documentID, job.generation]
                    )
                    reachedRetryLimit = reachedRetryLimit || db.changesCount > 0
                    continue
                }
                try db.execute(
                    sql: """
                    UPDATE search_index_jobs SET status = 'pending', availableAt = ?, claimedAt = NULL,
                        leaseExpiresAt = NULL, lastErrorCode = ?, updatedAt = ?
                    WHERE indexKind = 'vector' AND targetKind = 'document'
                      AND targetKey = ? AND generation = ?
                    """,
                    arguments: [
                        Date().addingTimeInterval(30), failure.errorCode, Date(),
                        job.documentID, job.generation,
                    ]
                )
            }
            return reachedRetryLimit
        }
        if reachedRetryLimit { throw VectorSearchIndexError.retryLimitReached }
    }

    private func markReadyIfComplete() async throws {
        try await dbQueue.write { db in
            let pending = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM search_index_jobs WHERE indexKind = 'vector'"
            ) ?? 0
            guard pending == 0 else { return }
            try db.execute(
                sql: """
                UPDATE search_index_state SET phase = 'ready', completedCount = totalCount,
                    lastErrorCode = NULL, updatedAt = ?
                WHERE indexKind = 'vector' AND isEnabled = 1
                """,
                arguments: [Date()]
            )
        }
    }

    private func recordFailure(_ error: Error) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE search_index_state SET phase = 'failed', lastErrorCode = ?, updatedAt = ?
                WHERE indexKind = 'vector'
                """,
                arguments: [String(describing: type(of: error)), Date()]
            )
        }
    }

    private func canDrain() async -> Bool {
        await (try? dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT isEnabled = 1 AND phase IN ('metadata', 'ready')
                    AND analyzerConfigurationHash = ?
                FROM search_index_state WHERE indexKind = 'vector'
                """,
                arguments: [EmbeddingGemmaDescriptor.configurationHash]
            ) ?? false
        }) ?? false
    }
}

private struct VectorSearchJob: Sendable {
    let documentID: Int64
    let generation: Int
    let attempts: Int
}

private struct VectorSearchFailure: Sendable {
    let job: VectorSearchJob
    let errorCode: String
}

private struct VectorDocument: Sendable {
    let title: String
    let text: String
    let sourceContentHash: String

    static func fetch(id: Int64, in db: Database) throws -> Self? {
        guard let document = try Row.fetchOne(
            db,
            sql: "SELECT kind, sourceId, sourceContentHash FROM search_documents WHERE id = ?",
            arguments: [id]
        ) else { return nil }
        let kind: String = document["kind"]
        let sourceID: UUID = document["sourceId"]
        let sourceContentHash: String = document["sourceContentHash"]
        if kind == "project" {
            guard let project = try ProjectRecord.fetchResolved(id: sourceID, in: db) else { return nil }
            return Self(
                title: project.name,
                text: [project.description, project.path].filter { !$0.isEmpty }.joined(separator: "\n"),
                sourceContentHash: sourceContentHash
            )
        }
        guard let meeting = try MeetingRecord.fetchOne(db, key: sourceID) else { return nil }
        let calendar = try Row.fetchOne(
            db,
            sql: """
            SELECT title, description FROM calendar_events
            WHERE ical_uid = ? AND recurrence_id = ?
            """,
            arguments: [meeting.calendarEventIcalUid, meeting.calendarEventRecurrenceId]
        )
        let tags = try String.fetchAll(
            db,
            sql: """
            SELECT tags.name FROM tags JOIN meeting_tags ON meeting_tags.tagId = tags.id
            WHERE meeting_tags.meetingId = ? ORDER BY tags.id
            """,
            arguments: [sourceID]
        ).joined(separator: " ")
        let summary = try SummaryRecord.fetchOne(db, key: sourceID)
            .flatMap { try? $0.loadDocument().searchableBodyText } ?? ""
        let semanticContent = [meeting.description, summary]
        guard semanticContent.joined().filter({ !$0.isWhitespace }).count >= 80 else { return nil }
        let projectPath = try meeting.projectId.flatMap { try ProjectRecord.fetchResolved(id: $0, in: db)?.path } ?? ""
        let calendarText = [calendar?["title"] as String?, calendar?["description"] as String?]
            .compactMap(\.self).joined(separator: " ")
        let title = meeting.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (semanticContent + [calendarText, tags, projectPath])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        return Self(
            title: title,
            text: text,
            sourceContentHash: sourceContentHash
        )
    }
}

private enum VectorSearchIndexError: Error {
    case resultCountMismatch
    case retryLimitReached
}

private func errorCode(_ error: Error) -> String {
    String(describing: type(of: error))
}
