import DahliaMeetingAccess
import Dispatch
import Foundation
import GRDB

actor SearchIndexer {
    typealias RuntimeProviderResolver = @Sendable () -> CodexRuntimeProvider

    private let dbQueue: DatabaseQueue
    private let screenshotAnalyzer: any ScreenshotAnalyzing
    private let runtimeProviderResolver: RuntimeProviderResolver
    private let observationQueue = DispatchQueue(label: "app.dahlia.search-indexer", qos: .utility)
    private var workerTask: Task<Void, Never>?
    private var observationDrainTask: Task<Void, Never>?
    private var activeDrainTask: Task<Void, Never>?
    private var jobObservation: AnyDatabaseCancellable?
    private var isDraining = false
    private var isPaused = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var didValidateAnalyzer = false
    private var lastDivergenceCheckAt: Date?

    private static let divergenceCheckInterval: TimeInterval = 15 * 60
    private static let maximumConcurrentScreenshotAnalysisCount = 8

    init(
        dbQueue: DatabaseQueue,
        screenshotAnalyzer: any ScreenshotAnalyzing = CodexScreenshotAnalysisService(),
        runtimeProviderResolver: @escaping RuntimeProviderResolver = { CodexRuntimeContextStore.shared.provider }
    ) {
        self.dbQueue = dbQueue
        self.screenshotAnalyzer = screenshotAnalyzer
        self.runtimeProviderResolver = runtimeProviderResolver
    }

    func start() async {
        guard workerTask == nil else { return }
        isPaused = false
        let observation = ValueObservation.tracking { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) + COALESCE(SUM(generation), 0)
                FROM search_index_jobs WHERE indexKind = 'fts'
                """
            ) ?? 0
        }.removeDuplicates()
        jobObservation = observation.start(
            in: dbQueue,
            scheduling: .async(onQueue: observationQueue),
            onError: { _ in },
            onChange: { [weak self] _ in
                Task { await self?.scheduleObservationDrain() }
            }
        )
        workerTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                await self?.drainScheduledWork()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() async {
        await stopOwnWorker()
    }

    func pauseForRecording() async {
        await stopOwnWorker()
    }

    private func stopOwnWorker() async {
        isPaused = true
        let tasks = [workerTask, observationDrainTask, activeDrainTask].compactMap(\.self)
        tasks.forEach { $0.cancel() }
        workerTask = nil
        observationDrainTask = nil
        jobObservation?.cancel()
        jobObservation = nil
        for task in tasks {
            await task.value
        }
        activeDrainTask = nil
        if isDraining {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
    }

    func requestRebuild() async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE search_index_jobs
                SET status = 'pending', attempts = 0, availableAt = ?, claimedAt = NULL,
                    leaseExpiresAt = NULL, lastErrorCode = NULL, updatedAt = ?
                WHERE indexKind = 'fts' AND targetKind = 'screenshotAnalysis' AND attempts >= 5
                """,
                arguments: [Date(), Date()]
            )
            try db.execute(
                sql: """
                UPDATE search_index_state
                SET indexGeneration = indexGeneration + 1,
                    phase = 'pending', completedCount = 0, totalCount = 0,
                    lastErrorCode = NULL, updatedAt = ?
                WHERE indexKind = 'fts'
                """,
                arguments: [Date()]
            )
        }
        await drain()
    }

    func drain() async {
        await runDrain(checksDivergence: true)
    }

    private func drainScheduledWork() async {
        guard workerTask != nil, !isPaused else { return }
        let now = Date()
        let checksDivergence = lastDivergenceCheckAt.map {
            now.timeIntervalSince($0) >= Self.divergenceCheckInterval
        } ?? true
        await runDrain(checksDivergence: checksDivergence)
    }

    private func runDrain(checksDivergence: Bool) async {
        if let activeDrainTask {
            await activeDrainTask.value
            return
        }
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.performDrain(checksDivergence: checksDivergence)
        }
        activeDrainTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        activeDrainTask = nil
    }

    private func performDrain(checksDivergence: Bool) async {
        guard !isDraining, !isPaused else { return }
        isDraining = true
        defer {
            isDraining = false
            drainWaiters.forEach { $0.resume() }
            drainWaiters.removeAll()
        }
        do {
            let phase = try await indexPhase()
            if phase == "failed" {
                try await drainCleanupJobs()
                return
            }
            try await validateAnalyzer()
            if try await needsRebuild(phase: phase, checksDivergence: checksDivergence) {
                try await rebuild()
            }
            while !isPaused, let jobs = try await claimNextJobs() {
                if jobs.first?.targetKind == "screenshotAnalysis" {
                    do {
                        if try await processScreenshotJobsConcurrently(jobs) { return }
                    } catch is CancellationError {
                        try await release(jobs)
                        return
                    } catch {
                        for job in jobs {
                            try await fail(job, error: error)
                        }
                    }
                    continue
                }
                do {
                    try await process(jobs)
                    try await complete(jobs)
                } catch is CancellationError {
                    try await release(jobs)
                    return
                } catch {
                    for job in jobs {
                        try await fail(job, error: error)
                    }
                }
            }
        } catch is CancellationError {
        } catch {
            try? await recordFailure(error)
        }
    }

    private func drainCleanupJobs() async throws {
        while !isPaused, let jobs = try await claimNextJobs(cleanupOnly: true) {
            do {
                try await process(jobs)
                try await complete(jobs)
            } catch is CancellationError {
                try await release(jobs)
                return
            } catch {
                for job in jobs {
                    try await fail(job, error: error)
                }
            }
        }
    }

    private func scheduleObservationDrain() {
        guard !isPaused, observationDrainTask == nil else { return }
        observationDrainTask = Task(priority: .utility) { [weak self] in
            await self?.runObservationDrain()
        }
    }

    private func runObservationDrain() async {
        await drainScheduledWork()
        observationDrainTask = nil
    }

    private func indexPhase() async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'fts'")
        }
    }

    private func validateAnalyzer() async throws {
        guard !didValidateAnalyzer else { return }
        try await dbQueue.read { db in
            _ = try db.makeTokenizer(SearchFTS5Tokenizer.tokenizerDescriptor())
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT analyzerVersion, analyzerConfigurationHash FROM search_index_state WHERE indexKind = 'fts'"
            ),
                row["analyzerVersion"] == SearchDocumentsMigration.analyzerVersion,
                row["analyzerConfigurationHash"] == SearchDocumentsMigration.analyzerConfigurationHash
            else {
                throw SearchIndexError.analyzerMismatch
            }
        }
        didValidateAnalyzer = true
    }

    private func needsRebuild(phase: String?, checksDivergence: Bool) async throws -> Bool {
        guard phase == "ready" else { return true }
        guard checksDivergence else { return false }
        let isDiverged = try await dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM search_documents
                    LEFT JOIN search_documents_fts ON search_documents_fts.rowid = search_documents.id
                    WHERE search_documents_fts.rowid IS NULL
                ) OR EXISTS(
                    SELECT 1 FROM search_documents_fts
                    LEFT JOIN search_documents ON search_documents.id = search_documents_fts.rowid
                    WHERE search_documents.id IS NULL
                )
                """
            ) ?? false
        }
        lastDivergenceCheckAt = .now
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE search_index_state SET lastIntegrityCheckAt = ?, updatedAt = ? WHERE indexKind = 'fts'",
                arguments: [Date(), Date()]
            )
        }
        guard isDiverged else { return false }
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE search_index_state
                SET indexGeneration = indexGeneration + 1, phase = 'pending', updatedAt = ?
                WHERE indexKind = 'fts'
                """,
                arguments: [Date()]
            )
        }
        return true
    }

    private func rebuild() async throws {
        let generation = try await dbQueue.write { db in
            let generation = try Int.fetchOne(
                db,
                sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'fts'"
            ) ?? 1
            let total = try Int.fetchOne(
                db,
                sql: """
                SELECT (SELECT COUNT(*) FROM meetings)
                     + (SELECT COUNT(*) FROM projects)
                     + (SELECT COUNT(*) FROM screenshots WHERE ocrText IS NOT NULL AND caption IS NOT NULL)
                """
            ) ?? 0
            try db.execute(
                sql: """
                UPDATE search_index_state
                SET phase = 'metadata', totalCount = ?, completedCount = 0,
                    lastErrorCode = NULL, updatedAt = ? WHERE indexKind = 'fts'
                """,
                arguments: [total, Date()]
            )
            return generation
        }

        let projectIDs = try await dbQueue.read { db in
            try UUID.fetchAll(db, sql: "SELECT id FROM projects ORDER BY rowid")
        }
        for id in projectIDs {
            try checkCanContinue()
            try await indexProject(id: id, generation: generation)
            try await incrementRebuildProgress()
        }

        let meetingIDs = try await dbQueue.read { db in
            try UUID.fetchAll(db, sql: "SELECT id FROM meetings ORDER BY rowid")
        }
        for id in meetingIDs {
            try checkCanContinue()
            try await indexMeeting(id: id, generation: generation)
            try await incrementRebuildProgress()
        }

        let screenshotIDs = try await dbQueue.read { db in
            try UUID.fetchAll(
                db,
                sql: "SELECT id FROM screenshots WHERE ocrText IS NOT NULL AND caption IS NOT NULL ORDER BY rowid"
            )
        }
        for id in screenshotIDs {
            try checkCanContinue()
            try await indexScreenshot(id: id, generation: generation)
            try await incrementRebuildProgress()
        }

        try await removeDocumentsOlderThan(generation: generation)
        try await removeOrphanedFTSRows()
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO search_documents_fts(search_documents_fts) VALUES('integrity-check')")
            try db.execute(
                sql: """
                UPDATE search_index_state
                SET phase = 'ready', indexRevision = indexRevision + 1,
                    completedCount = totalCount, lastErrorCode = NULL,
                    lastIntegrityCheckAt = ?, updatedAt = ?
                WHERE indexKind = 'fts'
                """,
                arguments: [Date(), Date()]
            )
        }
        lastDivergenceCheckAt = .now
    }

    private func checkCanContinue() throws {
        guard !isPaused else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func incrementRebuildProgress(by count: Int = 1) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE search_index_state
                SET completedCount = min(totalCount, completedCount + ?), updatedAt = ?
                WHERE indexKind = 'fts'
                """,
                arguments: [count, Date()]
            )
        }
    }

    private func claimNextJobs(cleanupOnly: Bool = false) async throws -> [SearchIndexJob]? {
        try await dbQueue.write { db in
            let now = Date()
            let cleanupFilter = cleanupOnly
                ? "AND targetKind IN ('vaultCleanup', 'meetingCleanup', 'projectCleanup', 'screenshotCleanup')"
                : ""
            guard let firstRow = try Row.fetchOne(
                db,
                sql: """
                SELECT targetKind, targetKey, generation, attempts
                FROM search_index_jobs
                WHERE indexKind = 'fts'
                  AND availableAt <= ?
                  AND attempts < 5
                  AND (status = 'pending' OR leaseExpiresAt < ?)
                  \(cleanupFilter)
                ORDER BY priority DESC, availableAt, targetKind, targetKey
                LIMIT 1
                """,
                arguments: [now, now]
            ) else { return nil }
            let targetKind: String = firstRow["targetKind"]
            let rows: [Row] = if targetKind == "screenshotAnalysis", !cleanupOnly {
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT targetKind, targetKey, generation, attempts
                    FROM search_index_jobs
                    WHERE indexKind = 'fts' AND targetKind = 'screenshotAnalysis'
                      AND availableAt <= ? AND attempts < 5
                      AND (status = 'pending' OR leaseExpiresAt < ?)
                    ORDER BY priority DESC, availableAt, targetKey
                    LIMIT ?
                    """,
                    arguments: [now, now, Self.maximumConcurrentScreenshotAnalysisCount]
                )
            } else {
                [firstRow]
            }
            let jobs = rows.map { row in
                let previousAttempts: Int = row["attempts"]
                return SearchIndexJob(
                    targetKind: row["targetKind"],
                    targetID: row["targetKey"],
                    generation: row["generation"],
                    attempts: previousAttempts + 1
                )
            }
            let leaseDuration: TimeInterval = targetKind == "screenshotAnalysis" ? 300 : 60
            for job in jobs {
                try db.execute(
                    sql: """
                    UPDATE search_index_jobs
                    SET status = 'processing', attempts = attempts + 1,
                        claimedAt = ?, leaseExpiresAt = ?, updatedAt = ?
                    WHERE indexKind = 'fts' AND targetKind = ? AND targetKey = ? AND generation = ?
                    """,
                    arguments: [
                        now,
                        now.addingTimeInterval(leaseDuration),
                        now,
                        job.targetKind,
                        job.targetID,
                        job.generation,
                    ]
                )
            }
            return jobs
        }
    }

    private func process(_ jobs: [SearchIndexJob]) async throws {
        let generation = try await currentGeneration()
        guard let job = jobs.first else { return }
        switch job.targetKind {
        case "vaultCleanup":
            try await deleteDocuments(where: "vaultId = ?", arguments: [job.targetID])
        case "meeting":
            try await indexMeeting(id: job.targetID, generation: generation)
        case "meetingCleanup":
            try await deleteDocuments(where: "meetingId = ?", arguments: [job.targetID])
        case "project":
            try await indexProject(id: job.targetID, generation: generation)
        case "projectHierarchy":
            try await reconcileProjectHierarchyChange(id: job.targetID, generation: generation)
        case "projectCleanup":
            try await deleteDocuments(
                where: "kind = 'project' AND projectId = ?",
                arguments: [job.targetID]
            )
        case "screenshotCleanup":
            try await deleteDocuments(
                where: "kind = 'screenshot' AND sourceId = ?",
                arguments: [job.targetID]
            )
        default:
            throw SearchIndexError.unknownJob(job.targetKind)
        }
    }

    private func currentGeneration() async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT indexGeneration FROM search_index_state WHERE indexKind = 'fts'") ?? 1
        }
    }

    private func reconcileProjectHierarchyChange(id: UUID, generation: Int) async throws {
        let affected = try await dbQueue.read { db -> ([ProjectRecord], [UUID: String]) in
            guard let project = try ProjectRecord.fetchOne(db, key: id) else { return ([], [:]) }
            let projects = try ProjectRecord.hierarchy(projectId: id, vaultId: project.vaultId, in: db)
            let paths = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.path) })
            guard !paths.isEmpty else { return ([], [:]) }
            let projectIDs = Array(paths.keys)
            let placeholders = Array(repeating: "?", count: projectIDs.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, projectId FROM meetings WHERE projectId IN (\(placeholders))",
                arguments: StatementArguments(projectIDs)
            )
            let meetingPaths = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (UUID, String)? in
                let meetingID: UUID = row["id"]
                let meetingProjectID: UUID = row["projectId"]
                return paths[meetingProjectID].map { (meetingID, $0) }
            })
            return (projects, meetingPaths)
        }
        for project in affected.0 {
            try await indexProject(project, generation: generation)
        }
        for (meetingID, projectPath) in affected.1 {
            try await indexMeeting(id: meetingID, generation: generation, projectPath: projectPath)
        }
    }
}

private extension SearchIndexer {
    func indexScreenshot(id: UUID, generation: Int) async throws {
        try await dbQueue.write { db in
            try indexScreenshotDocument(id: id, generation: generation, in: db)
        }
    }

    func processScreenshotJobsConcurrently(_ jobs: [SearchIndexJob]) async throws -> Bool {
        let inputs = try await dbQueue.read { db in
            try Dictionary(uniqueKeysWithValues: jobs.compactMap { job -> (UUID, ScreenshotAnalysisInput)? in
                guard let screenshot = try MeetingScreenshotRecord.fetchOne(db, key: job.targetID),
                      let meeting = try MeetingRecord.fetchOne(db, key: screenshot.meetingId),
                      let vault = try VaultRecord.fetchOne(db, key: meeting.vaultId)
                else { return nil }
                return (job.targetID, ScreenshotAnalysisInput(
                    id: screenshot.id,
                    imageData: screenshot.imageData,
                    mimeType: screenshot.mimeType,
                    runtimeProvider: CodexRuntimeProvider(
                        accountConnectionID: vault.accountConnectionId,
                        localProvider: vault.localProvider,
                        databricksProfile: vault.databricksProfile
                    )
                ))
            })
        }
        var outcomes = jobs.compactMap { job in
            inputs[job.targetID] == nil ? ScreenshotJobOutcome.missing(job) : nil
        }
        let runtimeProvider = runtimeProviderResolver()
        let deferredJobs = jobs.filter { job in
            guard let input = inputs[job.targetID] else { return false }
            return input.runtimeProvider != runtimeProvider
        }
        try await deferScreenshotJobsForRuntime(deferredJobs)
        var prerequisiteError: (any Error)?
        await withTaskGroup(of: ScreenshotJobOutcome.self) { group in
            for job in jobs {
                guard let input = inputs[job.targetID], input.runtimeProvider == runtimeProvider else { continue }
                group.addTask(priority: .utility) { [screenshotAnalyzer] in
                    do {
                        let results = try await screenshotAnalyzer.analyze([input])
                        try Task.checkCancellation()
                        return .success(job, results)
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .failure(job, error)
                    }
                }
            }
            for await outcome in group {
                outcomes.append(outcome)
                if case let .failure(_, error) = outcome,
                   Self.isDeferredScreenshotAnalysisError(error) {
                    prerequisiteError = prerequisiteError ?? error
                    group.cancelAll()
                }
            }
        }
        try Task.checkCancellation()

        if let prerequisiteError {
            try await deferScreenshotQueueForPrerequisite(prerequisiteError)
            return true
        }

        let generation = try await currentGeneration()
        for outcome in outcomes {
            switch outcome {
            case let .success(job, results):
                do {
                    try await storeScreenshotAnalyses(results, generation: generation)
                    try await complete([job])
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try await fail(job, error: error)
                }
            case let .failure(job, error):
                try await fail(job, error: error)
            case let .missing(job):
                try await complete([job])
            case .cancelled:
                throw CancellationError()
            }
        }
        return false
    }

    func storeScreenshotAnalyses(_ results: [ScreenshotAnalysis], generation: Int) async throws {
        try await dbQueue.write { db in
            for result in results {
                guard try MeetingScreenshotRecord.fetchOne(db, key: result.screenshotID) != nil else { continue }
                try db.execute(
                    sql: "UPDATE screenshots SET ocrText = ?, caption = ? WHERE id = ?",
                    arguments: [result.ocrText, result.caption, result.screenshotID]
                )
                if let screenshot = try MeetingScreenshotRecord.fetchOne(db, key: result.screenshotID),
                   let vaultId = try UUID.fetchOne(
                       db,
                       sql: "SELECT vaultId FROM meetings WHERE id = ?",
                       arguments: [screenshot.meetingId]
                   ) {
                    try SyncTransactionRecorder.record(
                        vaultId: vaultId,
                        operations: [SyncInitialSnapshotBuilder.screenshotOperation(screenshot, action: .upsert)],
                        in: db
                    )
                }
                try indexScreenshotDocument(id: result.screenshotID, generation: generation, in: db)
            }
        }
    }

    func indexMeeting(
        id: UUID,
        generation: Int,
        projectPath knownProjectPath: String? = nil
    ) async throws {
        try await dbQueue.write { db in
            guard let meeting = try MeetingRecord.fetchOne(db, key: id) else { return }
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
                arguments: [id]
            ).joined(separator: " ")
            let projectPath: String = if let knownProjectPath {
                knownProjectPath
            } else if let projectID = meeting.projectId {
                try ProjectRecord.fetchResolved(id: projectID, in: db)?.path ?? ""
            } else {
                ""
            }
            let calendarText = [calendar?["title"] as String?, calendar?["description"] as String?]
                .compactMap(\.self).joined(separator: " ")
            let summaryDocument = try SummaryRecord.fetchOne(db, key: id)
                .flatMap { try? $0.loadDocument() }
            let summaryText = summaryDocument?.searchableBodyText ?? ""
            let fields = SearchDocumentFields(
                title: meeting.name,
                description: meeting.description,
                summary: summaryText,
                calendar: calendarText,
                tags: tags,
                projectPath: projectPath,
                summaryDescription: summaryDocument?.description ?? ""
            )
            try db.execute(
                sql: "UPDATE search_documents SET projectId = ? WHERE meetingId = ? AND projectId IS NOT ?",
                arguments: [meeting.projectId, id, meeting.projectId]
            )
            let document = SearchDocumentProjection(
                kind: "meeting",
                sourceID: id,
                vaultID: meeting.vaultId,
                meetingID: id,
                projectID: meeting.projectId,
                fields: fields
            )
            try upsertDocument(document, generation: generation, in: db)
        }
    }

    private func indexProject(id: UUID, generation: Int) async throws {
        try await dbQueue.write { db in
            guard let project = try ProjectRecord.fetchResolved(id: id, in: db) else { return }
            try upsertDocument(
                Self.projectDocument(project),
                generation: generation,
                in: db
            )
        }
    }

    private func indexProject(
        _ project: ProjectRecord,
        generation: Int
    ) async throws {
        try await dbQueue.write { db in
            try upsertDocument(
                Self.projectDocument(project),
                generation: generation,
                in: db
            )
        }
    }

    static func projectDocument(_ project: ProjectRecord) -> SearchDocumentProjection {
        SearchDocumentProjection(
            kind: "project",
            sourceID: project.id,
            vaultID: project.vaultId,
            meetingID: nil,
            projectID: project.id,
            fields: SearchDocumentFields(
                title: project.name,
                description: project.description,
                calendar: "",
                tags: "",
                projectPath: project.path
            )
        )
    }

    private func removeDocumentsOlderThan(generation: Int) async throws {
        let ids = try await dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: "SELECT id FROM search_documents WHERE indexGeneration < ?",
                arguments: [generation]
            )
        }
        try await deleteDocuments(rowIDs: ids)
    }

    private func removeOrphanedFTSRows() async throws {
        let ids = try await dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                SELECT search_documents_fts.rowid FROM search_documents_fts
                LEFT JOIN search_documents ON search_documents.id = search_documents_fts.rowid
                WHERE search_documents.id IS NULL
                """
            )
        }
        for batch in ids.chunked(maximumCount: 50) {
            try await dbQueue.write { db in
                for id in batch {
                    try db.execute(sql: "DELETE FROM search_documents_fts WHERE rowid = ?", arguments: [id])
                }
            }
        }
    }

    private func deleteDocuments(
        where condition: String,
        arguments: StatementArguments
    ) async throws {
        let ids = try await dbQueue.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM search_documents WHERE \(condition)", arguments: arguments)
        }
        try await deleteDocuments(rowIDs: ids)
    }

    private nonisolated static func deleteDocuments(
        where condition: String,
        arguments: StatementArguments,
        in db: Database
    ) throws {
        let ids = try Int64.fetchAll(
            db,
            sql: "SELECT id FROM search_documents WHERE \(condition)",
            arguments: arguments
        )
        try Self.deleteDocuments(rowIDs: ids, in: db)
    }

    private func deleteDocuments(rowIDs: [Int64]) async throws {
        for batch in rowIDs.chunked(maximumCount: 50) {
            try await dbQueue.write { db in
                try Self.deleteDocuments(rowIDs: batch, in: db)
            }
        }
    }

    private nonisolated static func deleteDocuments(rowIDs: [Int64], in db: Database) throws {
        let previousSecureDelete = try Int.fetchOne(db, sql: "PRAGMA secure_delete") ?? 0
        try db.execute(sql: "PRAGMA secure_delete = ON")
        defer { try? db.execute(sql: "PRAGMA secure_delete = \(previousSecureDelete)") }
        for id in rowIDs {
            try db.execute(sql: "DELETE FROM search_documents_fts WHERE rowid = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM search_documents WHERE id = ?", arguments: [id])
        }
    }

    private func complete(_ jobs: [SearchIndexJob]) async throws {
        try await dbQueue.write { db in
            for job in jobs {
                try db.execute(
                    sql: """
                    DELETE FROM search_index_jobs
                    WHERE indexKind = 'fts' AND targetKind = ? AND targetKey = ? AND generation = ?
                    """,
                    arguments: [job.targetKind, job.targetID, job.generation]
                )
            }
            try db.execute(
                sql: """
                UPDATE search_index_state SET updatedAt = ?
                WHERE indexKind = 'fts'
                """,
                arguments: [Date()]
            )
        }
    }

    private func release(_ jobs: [SearchIndexJob]) async throws {
        try await Task.detached(priority: .utility) { [dbQueue] in
            try await dbQueue.write { db in
                for job in jobs {
                    try db.execute(
                        sql: """
                        UPDATE search_index_jobs
                        SET status = 'pending', attempts = max(0, attempts - 1), availableAt = ?,
                            claimedAt = NULL, leaseExpiresAt = NULL, updatedAt = ?
                        WHERE indexKind = 'fts' AND targetKind = ? AND targetKey = ? AND generation = ?
                        """,
                        arguments: [Date(), Date(), job.targetKind, job.targetID, job.generation]
                    )
                }
            }
        }.value
    }

    private func deferScreenshotQueueForPrerequisite(_ error: Error) async throws {
        let retryAt = Date().addingTimeInterval(60)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE search_index_jobs
                SET status = 'pending',
                    attempts = CASE WHEN status = 'processing' THEN MAX(0, attempts - 1) ELSE attempts END,
                    availableAt = MAX(availableAt, ?),
                    claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = ?, updatedAt = ?
                WHERE indexKind = 'fts' AND targetKind = 'screenshotAnalysis'
                  AND (status = 'processing' OR attempts < 5)
                """,
                arguments: [retryAt, String(describing: type(of: error)), Date()]
            )
        }
    }

    private func deferScreenshotJobsForRuntime(_ jobs: [SearchIndexJob]) async throws {
        guard !jobs.isEmpty else { return }
        let retryAt = Date().addingTimeInterval(60)
        try await dbQueue.write { db in
            for job in jobs {
                try db.execute(
                    sql: """
                    UPDATE search_index_jobs
                    SET status = 'pending', attempts = max(0, attempts - 1), availableAt = ?,
                        claimedAt = NULL, leaseExpiresAt = NULL, lastErrorCode = ?, updatedAt = ?
                    WHERE indexKind = 'fts' AND targetKind = ? AND targetKey = ? AND generation = ?
                    """,
                    arguments: [
                        retryAt, "runtimeProviderMismatch", Date(),
                        job.targetKind, job.targetID, job.generation,
                    ]
                )
            }
        }
    }

    private func fail(_ job: SearchIndexJob, error: Error) async throws {
        if job.attempts >= 5 {
            if job.targetKind == "screenshotAnalysis" {
                try await dbQueue.write { db in
                    try db.execute(
                        sql: """
                        UPDATE search_index_jobs
                        SET status = 'pending', claimedAt = NULL, leaseExpiresAt = NULL,
                            lastErrorCode = ?, updatedAt = ?
                        WHERE indexKind = 'fts' AND targetKind = ? AND targetKey = ? AND generation = ?
                        """,
                        arguments: [
                            String(describing: type(of: error)), Date(),
                            job.targetKind, job.targetID, job.generation,
                        ]
                    )
                }
                return
            }
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                    DELETE FROM search_index_jobs
                    WHERE indexKind = 'fts' AND targetKind = ? AND targetKey = ? AND generation = ?
                    """,
                    arguments: [
                        job.targetKind,
                        job.targetID,
                        job.generation,
                    ]
                )
            }
            throw SearchIndexError.retryLimitReached
        }
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE search_index_jobs
                SET status = 'pending', availableAt = ?, claimedAt = NULL, leaseExpiresAt = NULL,
                    lastErrorCode = ?, updatedAt = ?
                WHERE indexKind = 'fts' AND targetKind = ? AND targetKey = ? AND generation = ?
                """,
                arguments: [
                    Date().addingTimeInterval(30),
                    String(describing: type(of: error)),
                    Date(),
                    job.targetKind,
                    job.targetID,
                    job.generation,
                ]
            )
        }
    }

    nonisolated static func isDeferredScreenshotAnalysisError(_ error: Error) -> Bool {
        if error is CodexConfigurationError { return true }
        guard let error = error as? CodexAppServerError else { return false }
        return switch error {
        case .helperNotBundled, .notLoggedIn, .providerAuthenticationFailed, .requestedModelUnavailable:
            true
        default:
            false
        }
    }

    private func recordFailure(_ error: Error) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE search_index_state
                SET phase = 'failed', lastErrorCode = ?, updatedAt = ? WHERE indexKind = 'fts'
                """,
                arguments: [String(describing: type(of: error)), Date()]
            )
        }
    }
}

private struct SearchIndexJob: Sendable {
    let targetKind: String
    let targetID: UUID
    let generation: Int
    let attempts: Int
}

private enum ScreenshotJobOutcome: Sendable {
    case success(SearchIndexJob, [ScreenshotAnalysis])
    case failure(SearchIndexJob, any Error)
    case cancelled
    case missing(SearchIndexJob)
}

private enum SearchIndexError: Error {
    case analyzerMismatch
    case retryLimitReached
    case unknownJob(String)
}

private extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        guard !isEmpty else { return [] }
        return stride(from: 0, to: count, by: maximumCount).map {
            Array(self[$0 ..< Swift.min($0 + maximumCount, count)])
        }
    }
}
