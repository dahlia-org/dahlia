import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    // swiftlint:disable:next type_body_length
    struct ScreenshotOCRSearchTests {
        @Test
        func storesOCRAndReturnsTheImageWithoutMergingItsMeeting() async throws {
            let database = try AppDatabaseManager(
                path: ":memory:",
                screenshotAnalyzer: StubScreenshotAnalyzer(text: "画像だけの固有検索語")
            )
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            let screenshot = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: meeting.id,
                sessionId: nil,
                capturedAt: .now,
                imageData: Data([1, 2, 3]),
                mimeType: "image/png"
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try screenshot.insert(db)
            }

            let coreSearchHasPriority = try await database.dbQueue.read { db in
                try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT
                        (SELECT priority FROM search_index_jobs WHERE targetKind = 'meeting' AND targetKey = ?)
                        >
                        (SELECT priority FROM search_index_jobs WHERE targetKind = 'screenshotAnalysis' AND targetKey = ?)
                    """,
                    arguments: [meeting.id, screenshot.id]
                ) ?? false
            }
            #expect(coreSearchHasPriority)

            await database.searchIndexer.drain()

            let storedText = try await database.dbQueue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT ocrText FROM screenshots WHERE id = ?",
                    arguments: [screenshot.id]
                )
            }
            let screenshotPage = try await MeetingRepository.searchScreenshotPage(
                vaultID: vault.id,
                criteria: MeetingSearchCriteria(text: "固有検索語"),
                limit: 20,
                dbQueue: database.dbQueue
            )
            let captionPage = try await MeetingRepository.searchScreenshotPage(
                vaultID: vault.id,
                criteria: MeetingSearchCriteria(text: "画像の説明"),
                limit: 20,
                dbQueue: database.dbQueue
            )
            let meetingPage = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: vault.id,
                query: "固有検索語",
                limit: 20,
                dbQueue: database.dbQueue
            )
            #expect(storedText == "画像だけの固有検索語")
            #expect(screenshotPage.items.map(\.id) == [screenshot.id])
            #expect(captionPage.items.map(\.id) == [screenshot.id])
            #expect(screenshotPage.items.first?.meetingID == meeting.id)
            #expect(screenshotPage.items.first?.meetingDescription == "検索対象のミーティング説明")
            #expect(meetingPage.items.isEmpty)
        }

        @Test
        func ocrMatchRanksAboveCaptionOnlyMatch() async throws {
            let ocrMatchID = UUID.v7()
            let captionMatchID = UUID.v7()
            let database = try AppDatabaseManager(
                path: ":memory:",
                screenshotAnalyzer: FieldTargetedScreenshotAnalyzer(ocrMatchID: ocrMatchID)
            )
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                // caption マッチ側を新しくし、BM25 が同点なら capturedAt DESC で先頭に来る配置にする
                for (id, second) in [(ocrMatchID, 0), (captionMatchID, 1)] {
                    try MeetingScreenshotRecord(
                        id: id,
                        meetingId: meeting.id,
                        sessionId: nil,
                        capturedAt: Date(timeIntervalSince1970: TimeInterval(second)),
                        imageData: Data([UInt8(second)]),
                        mimeType: "image/png"
                    ).insert(db)
                }
            }

            await database.searchIndexer.drain()

            let page = try await MeetingRepository.searchScreenshotPage(
                vaultID: vault.id,
                criteria: MeetingSearchCriteria(text: "重み検証語"),
                limit: 20,
                dbQueue: database.dbQueue
            )
            #expect(page.items.map(\.id) == [ocrMatchID, captionMatchID])

            // screenshotRankingSQL の bm25 重みは FTS カラム位置に対応するため、カラム順の変更を検知する
            let columns = try await database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('search_documents_fts')")
            }
            #expect(columns == ["title", "description", "summary", "calendar", "tags", "projectPath", "ocr", "caption"])
        }

        @Test
        func recordingPauseLeavesOCRQueuedUntilRestart() async throws {
            let database = try AppDatabaseManager(
                path: ":memory:",
                screenshotAnalyzer: StubScreenshotAnalyzer(text: "録音終了後")
            )
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
            }
            await database.searchIndexer.drain()
            await database.searchIndexer.start()
            await database.searchIndexer.pauseForRecording()
            let screenshot = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: meeting.id,
                sessionId: nil,
                capturedAt: .now,
                imageData: Data([1]),
                mimeType: "image/png"
            )
            try await database.dbQueue.write { db in try screenshot.insert(db) }
            await database.searchIndexer.drain()
            let paused = try await database.dbQueue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT ocrText FROM screenshots WHERE id = ?",
                    arguments: [screenshot.id]
                )
            }
            #expect(paused == nil)

            await database.searchIndexer.start()
            #expect(await pollUntil {
                await (try? database.dbQueue.read { db in
                    try String.fetchOne(
                        db,
                        sql: "SELECT ocrText FROM screenshots WHERE id = ?",
                        arguments: [screenshot.id]
                    ) == "録音終了後"
                }) ?? false
            })
            await database.searchIndexer.stop()
        }

        @Test
        func recordingPauseCancelsAllInFlightOCRAndRequeuesIt() async throws {
            let analyzer = CancellableScreenshotAnalyzer()
            let database = try AppDatabaseManager(path: ":memory:", screenshotAnalyzer: analyzer)
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
            }
            await database.searchIndexer.drain()
            await database.searchIndexer.start()
            let screenshots = (0 ..< 8).map { index in
                MeetingScreenshotRecord(
                    id: .v7(),
                    meetingId: meeting.id,
                    sessionId: nil,
                    capturedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    imageData: Data([UInt8(index)]),
                    mimeType: "image/png"
                )
            }
            try await database.dbQueue.write { db in
                for screenshot in screenshots {
                    try screenshot.insert(db)
                }
            }
            #expect(await pollUntil { await analyzer.startedCount == 8 })

            await database.searchIndexer.pauseForRecording()

            let state = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM screenshots WHERE ocrText IS NOT NULL"
                    ) ?? 0,
                    Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM search_index_jobs
                        WHERE targetKind = 'screenshotAnalysis' AND status = 'pending'
                        """
                    ) ?? 0
                )
            }
            #expect(state.0 == 0)
            #expect(state.1 == 8)
            #expect(await analyzer.cancelledCount == 8)
        }

        @Test(.timeLimit(.minutes(1)))
        func recordingPauseCancelsExplicitRebuildOCRAndRequeuesIt() async throws {
            let analyzer = CancellableScreenshotAnalyzer()
            let database = try AppDatabaseManager(path: ":memory:", screenshotAnalyzer: analyzer)
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                for index in 0 ..< 8 {
                    try MeetingScreenshotRecord(
                        id: .v7(),
                        meetingId: meeting.id,
                        sessionId: nil,
                        capturedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                        imageData: Data([UInt8(index)]),
                        mimeType: "image/png"
                    ).insert(db)
                }
            }
            let rebuildTask = Task { try await database.searchIndexer.requestRebuild() }
            #expect(await pollUntil { await analyzer.startedCount == 8 })

            await database.searchIndexer.pauseForRecording()
            try await rebuildTask.value

            let state = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screenshots WHERE ocrText IS NOT NULL") ?? 0,
                    Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM search_index_jobs
                        WHERE targetKind = 'screenshotAnalysis' AND status = 'pending'
                        """
                    ) ?? 0
                )
            }
            #expect(state == (0, 8))
            #expect(await analyzer.cancelledCount == 8)
        }

        @Test
        func staleScreenshotCursorReplacesResults() async throws {
            let database = try AppDatabaseManager(
                path: ":memory:",
                screenshotAnalyzer: StubScreenshotAnalyzer(text: "cursor needle")
            )
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                for second in 0 ... 1 {
                    try MeetingScreenshotRecord(
                        id: .v7(),
                        meetingId: meeting.id,
                        sessionId: nil,
                        capturedAt: Date(timeIntervalSince1970: TimeInterval(second)),
                        imageData: Data([UInt8(second)]),
                        mimeType: "image/png"
                    ).insert(db)
                }
            }
            await database.searchIndexer.drain()
            let first = try await MeetingRepository.searchScreenshotPage(
                vaultID: vault.id,
                criteria: MeetingSearchCriteria(text: "cursor needle"),
                limit: 1,
                dbQueue: database.dbQueue
            )
            let cursor = try #require(first.nextCursor)
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE search_index_state SET indexRevision = indexRevision + 1 WHERE indexKind = 'fts'"
                )
            }

            let refreshed = try await MeetingRepository.searchScreenshotPage(
                vaultID: vault.id,
                criteria: MeetingSearchCriteria(text: "cursor needle"),
                after: cursor,
                limit: 1,
                dbQueue: database.dbQueue
            )
            #expect(refreshed.replacesResults)
            #expect(refreshed.items.map(\.id) == first.items.map(\.id))
        }

        @Test(.timeLimit(.minutes(1)))
        func analyzesSingleScreenshotsUpToEightConcurrently() async throws {
            let analyzer = ConcurrentScreenshotAnalyzer()
            let database = try AppDatabaseManager(path: ":memory:", screenshotAnalyzer: analyzer)
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            let screenshots = (0 ..< 9).map { index in
                MeetingScreenshotRecord(
                    id: .v7(),
                    meetingId: meeting.id,
                    sessionId: nil,
                    capturedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    imageData: Data([UInt8(index)]),
                    mimeType: "image/png"
                )
            }
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                for screenshot in screenshots {
                    try screenshot.insert(db)
                }
            }

            let drainTask = Task { await database.searchIndexer.drain() }
            let startedFirstWave = await pollUntil { await analyzer.callSizes.count == 8 }
            await analyzer.releaseFirstWave()
            await drainTask.value

            #expect(startedFirstWave)
            #expect(await analyzer.callSizes == Array(repeating: 1, count: 9))
            #expect(await analyzer.activeCountsAtStart == Array(1 ... 8) + [1])
            #expect(await analyzer.maximumActiveCount == 8)
            let indexedCount = try await database.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM screenshots WHERE ocrText IS NOT NULL AND caption IS NOT NULL"
                ) ?? 0
            }
            #expect(indexedCount == 9)
        }

        @Test
        func concurrentFailureIsolatesTheFailingScreenshot() async throws {
            let failingID = UUID.v7()
            let analyzer = FailingOneScreenshotAnalyzer(failingID: failingID)
            let database = try AppDatabaseManager(path: ":memory:", screenshotAnalyzer: analyzer)
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            let screenshots = [failingID] + (0 ..< 7).map { _ in UUID.v7() }
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                for id in screenshots {
                    try MeetingScreenshotRecord(
                        id: id,
                        meetingId: meeting.id,
                        sessionId: nil,
                        capturedAt: .now,
                        imageData: Data([1]),
                        mimeType: "image/png"
                    ).insert(db)
                }
            }

            await database.searchIndexer.drain()

            let state = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM screenshots WHERE ocrText = 'isolated text'"
                    ) ?? 0,
                    Int.fetchOne(
                        db,
                        sql: "SELECT attempts FROM search_index_jobs WHERE targetKey = ?",
                        arguments: [failingID]
                    ),
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_index_jobs WHERE targetKind = 'screenshotAnalysis'") ?? 0
                )
            }
            #expect(state.0 == 7)
            #expect(state.1 == 1)
            #expect(state.2 == 1)
            #expect(await analyzer.callSizes == Array(repeating: 1, count: 8))
        }

        @Test
        func screenshotPersistenceFailureOnlyRetriesTheAffectedJob() async throws {
            let failingID = UUID.v7()
            let analyzer = StubScreenshotAnalyzer(text: "stored text")
            let database = try AppDatabaseManager(path: ":memory:", screenshotAnalyzer: analyzer)
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            let screenshotIDs = [failingID] + (0 ..< 7).map { _ in UUID.v7() }
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                for id in screenshotIDs {
                    try MeetingScreenshotRecord(
                        id: id,
                        meetingId: meeting.id,
                        sessionId: nil,
                        capturedAt: .now,
                        imageData: id == failingID ? Data([255]) : Data([1]),
                        mimeType: "image/png"
                    ).insert(db)
                }
                try db.execute(
                    sql: """
                    CREATE TEMP TRIGGER reject_screenshot_analysis
                    BEFORE UPDATE OF ocrText, caption ON screenshots
                    WHEN OLD.imageData = X'FF'
                    BEGIN
                        SELECT RAISE(FAIL, 'forced screenshot persistence failure');
                    END
                    """
                )
            }

            await database.searchIndexer.drain()

            let state = try database.dbQueue.read { db -> (Int, Int, Row?) in
                try (
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screenshots WHERE ocrText = 'stored text'") ?? 0,
                    Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM search_index_jobs
                        WHERE targetKind = 'screenshotAnalysis' AND targetKey != ?
                        """,
                        arguments: [failingID]
                    ) ?? 0,
                    Row.fetchOne(
                        db,
                        sql: """
                        SELECT status, attempts FROM search_index_jobs
                        WHERE targetKind = 'screenshotAnalysis' AND targetKey = ?
                        """,
                        arguments: [failingID]
                    )
                )
            }
            #expect(state.0 == 7)
            #expect(state.1 == 0)
            #expect(state.2?["status"] as String? == "pending")
            #expect(state.2?["attempts"] as Int? == 1)
        }

        @Test(.timeLimit(.minutes(1)))
        func unavailableRequiredModelBacksOffTheEntireScreenshotQueue() async throws {
            let failingID = try #require(UUID(uuidString: "00000000-0000-7000-8000-000000000000"))
            let analyzer = PrerequisiteRetryAnalyzer(failingID: failingID)
            let database = try AppDatabaseManager(path: ":memory:", screenshotAnalyzer: analyzer)
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            let screenshots = ([failingID] + (0 ..< 8).map { _ in UUID.v7() }).enumerated().map { index, id in
                MeetingScreenshotRecord(
                    id: id,
                    meetingId: meeting.id,
                    sessionId: nil,
                    capturedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    imageData: Data([UInt8(index)]),
                    mimeType: "image/png"
                )
            }
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                for screenshot in screenshots {
                    try screenshot.insert(db)
                }
                try db.execute(
                    sql: "UPDATE search_index_jobs SET attempts = 3 WHERE targetKind = 'screenshotAnalysis'"
                )
            }

            let drainTask = Task { await database.searchIndexer.drain() }
            let startedFirstWave = await pollUntil { await analyzer.firstWaveStartedCount == 8 }
            let triggeredFailure = await analyzer.failFirstWave()
            if !triggeredFailure { drainTask.cancel() }
            await drainTask.value
            let deferred = try database.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) AS pendingCount, SUM(attempts = 3) AS preservedAttempts, MIN(availableAt) AS availableAt
                    FROM search_index_jobs WHERE targetKind = 'screenshotAnalysis' AND status = 'pending'
                    """
                )
            }
            #expect(startedFirstWave)
            #expect(deferred?["pendingCount"] as Int? == 9)
            #expect(deferred?["preservedAttempts"] as Int? == 9)
            #expect((deferred?["availableAt"] as Date? ?? .distantPast) > .now)
            #expect(await analyzer.firstWaveStartedCount == 8)
            #expect(await analyzer.firstWaveCancelledCount == 7)

            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE search_index_jobs SET availableAt = ? WHERE targetKind = 'screenshotAnalysis'",
                    arguments: [Date.distantPast]
                )
            }
            await database.searchIndexer.drain()

            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM screenshots WHERE ocrText = 'retry text' AND caption = 'retry caption'"
                ) ?? 0
            } == 9)
        }

        @Test
        func exhaustedOCRJobIsTerminalUntilExplicitRebuild() async throws {
            let database = try AppDatabaseManager(path: ":memory:", screenshotAnalyzer: FailingScreenshotAnalyzer())
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            let screenshot = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: meeting.id,
                sessionId: nil,
                capturedAt: .now,
                imageData: Data([1]),
                mimeType: "image/png"
            )
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
            }
            await database.searchIndexer.drain()
            try await database.dbQueue.write { db in
                try screenshot.insert(db)
                try db.execute(
                    sql: """
                    UPDATE search_index_jobs SET attempts = 4
                    WHERE targetKind = 'screenshotAnalysis' AND targetKey = ?
                    """,
                    arguments: [screenshot.id]
                )
            }

            await database.searchIndexer.drain()
            #expect(await pollUntil {
                await (try? database.dbQueue.read { db in
                    try Int.fetchOne(
                        db,
                        sql: """
                        SELECT attempts FROM search_index_jobs
                        WHERE targetKind = 'screenshotAnalysis' AND targetKey = ?
                        """,
                        arguments: [screenshot.id]
                    ) == 5
                }) ?? false
            })

            await database.searchIndexer.pauseForRecording()
            try await database.searchIndexer.requestRebuild()
            let reset = try database.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT status, attempts FROM search_index_jobs WHERE targetKind = 'screenshotAnalysis' AND targetKey = ?",
                    arguments: [screenshot.id]
                )
            }
            #expect(reset?["status"] as String? == "pending")
            #expect(reset?["attempts"] as Int? == 0)
        }

        @Test
        func migrationFromV37PreservesScreenshotsAndQueuesOCR() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v37_vectorSearch")
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            let screenshot = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: meeting.id,
                sessionId: nil,
                capturedAt: .now,
                imageData: Data([1, 2, 3]),
                mimeType: "image/png"
            )
            try queue.write { db in
                try insertLegacyVault(vault, in: db)
                try meeting.insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO screenshots(id, meetingId, sessionId, capturedAt, imageData, mimeType)
                    VALUES(?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        screenshot.id, screenshot.meetingId, screenshot.sessionId, screenshot.capturedAt,
                        screenshot.imageData, screenshot.mimeType,
                    ]
                )
            }

            try AppDatabaseManager.migrator.migrate(queue)

            let snapshot = try queue.read { db in
                try (
                    MeetingScreenshotRecord.fetchOne(db, key: screenshot.id),
                    Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('screenshots')")),
                    Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM search_index_jobs
                        WHERE indexKind = 'fts' AND targetKind = 'screenshotAnalysis' AND targetKey = ?
                        """,
                        arguments: [screenshot.id]
                    ) ?? 0,
                    String.fetchOne(db, sql: "SELECT phase FROM search_index_state WHERE indexKind = 'fts'")
                )
            }
            #expect(snapshot.0?.imageData == screenshot.imageData)
            #expect(snapshot.1.contains("ocrText"))
            #expect(snapshot.1.contains("caption"))
            #expect(snapshot.2 == 1)
            #expect(snapshot.3 == "pending")
        }

        @Test
        func migrationFromV37PreservesReadyVectorDocuments() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v37_vectorSearch")
            let documentID = try queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO search_documents(
                        kind, sourceId, vaultId, sourceContentHash, indexGeneration, updatedAt
                    ) VALUES('project', ?, ?, 'preserved', 1, ?)
                    """,
                    arguments: [UUID.v7(), UUID.v7(), Date.now]
                )
                let documentID = db.lastInsertedRowID
                try db.execute(
                    sql: """
                    INSERT INTO search_documents_vec(
                        documentId, embedding, sourceContentHash, indexGeneration, updatedAt
                    ) VALUES(?, ?, 'preserved', 1, ?)
                    """,
                    arguments: [documentID, Data(count: 1024), Date.now]
                )
                try db.execute(
                    sql: """
                    UPDATE search_index_state
                    SET isEnabled = 1, phase = 'ready'
                    WHERE indexKind = 'vector'
                    """
                )
                return documentID
            }

            try AppDatabaseManager.migrator.migrate(queue)

            let snapshot = try queue.read { db in
                try (
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents WHERE id = ?", arguments: [documentID]),
                    Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_vec WHERE documentId = ?", arguments: [documentID]),
                    Row.fetchOne(db, sql: "SELECT phase, isEnabled FROM search_index_state WHERE indexKind = 'vector'")
                )
            }
            #expect(snapshot.0 == 1)
            #expect(snapshot.1 == 1)
            #expect(snapshot.2?["phase"] as String? == "ready")
            #expect(snapshot.2?["isEnabled"] as Bool? == true)
        }

        @Test
        func reappliesUnreleasedV38ForDevelopmentDatabases() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue)
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            let screenshot = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: meeting.id,
                sessionId: nil,
                capturedAt: .now,
                imageData: Data([1]),
                mimeType: "image/png",
                ocrText: "old OCR",
                caption: "old caption"
            )
            try queue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try screenshot.insert(db)
                try db.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = 'v38_screenshotOCRSearch'"
                )
            }

            try AppDatabaseManager.migrator.migrate(queue)

            let state = try queue.read { db in
                try (
                    MeetingScreenshotRecord.fetchOne(db, key: screenshot.id),
                    Int.fetchOne(
                        db,
                        sql: """
                        SELECT COUNT(*) FROM search_index_jobs
                        WHERE targetKind = 'screenshotAnalysis' AND targetKey = ?
                        """,
                        arguments: [screenshot.id]
                    ) ?? 0,
                    Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('search_documents_fts')"))
                )
            }
            #expect(state.0?.ocrText == nil)
            #expect(state.0?.caption == nil)
            #expect(state.1 == 1)
            #expect(state.2.contains("caption"))
        }

        private func makeVault() -> VaultRecord {
            VaultRecord(
                id: .v7(),
                path: "/tmp/screenshot-ocr-search-vault",
                name: "Search",
                createdAt: .now,
                lastOpenedAt: .now
            )
        }

        private func makeMeeting(vaultID: UUID) -> MeetingRecord {
            MeetingRecord(
                id: .v7(),
                vaultId: vaultID,
                projectId: nil,
                name: "検索会議",
                description: "検索対象のミーティング説明",
                createdAt: .now,
                updatedAt: .now
            )
        }
    }

    private struct StubScreenshotAnalyzer: ScreenshotAnalyzing {
        let text: String
        func analyze(_ screenshots: [ScreenshotAnalysisInput]) async throws -> [ScreenshotAnalysis] {
            screenshots.map {
                ScreenshotAnalysis(screenshotID: $0.id, ocrText: text, caption: "画像の説明")
            }
        }
    }

    private struct FieldTargetedScreenshotAnalyzer: ScreenshotAnalyzing {
        let ocrMatchID: UUID
        func analyze(_ screenshots: [ScreenshotAnalysisInput]) async throws -> [ScreenshotAnalysis] {
            screenshots.map {
                $0.id == ocrMatchID
                    ? ScreenshotAnalysis(screenshotID: $0.id, ocrText: "重み検証語", caption: "無関係な説明")
                    : ScreenshotAnalysis(screenshotID: $0.id, ocrText: "無関係な文字", caption: "重み検証語")
            }
        }
    }

    private actor CancellableScreenshotAnalyzer: ScreenshotAnalyzing {
        private(set) var startedCount = 0
        private(set) var cancelledCount = 0

        func analyze(_ screenshots: [ScreenshotAnalysisInput]) async throws -> [ScreenshotAnalysis] {
            startedCount += 1
            do {
                try await Task.sleep(for: .seconds(60))
                return screenshots.map {
                    ScreenshotAnalysis(screenshotID: $0.id, ocrText: "late text", caption: "late caption")
                }
            } catch {
                cancelledCount += 1
                throw error
            }
        }
    }

    private struct FailingScreenshotAnalyzer: ScreenshotAnalyzing {
        func analyze(_: [ScreenshotAnalysisInput]) async throws -> [ScreenshotAnalysis] { throw Failure() }
        private struct Failure: Error {}
    }

    private actor ConcurrentScreenshotAnalyzer: ScreenshotAnalyzing {
        private(set) var callSizes: [Int] = []
        private(set) var activeCountsAtStart: [Int] = []
        private(set) var maximumActiveCount = 0
        private var activeCount = 0
        private var isFirstWaveBlocked = true
        private var firstWaveWaiters: [CheckedContinuation<Void, Never>] = []

        func analyze(_ screenshots: [ScreenshotAnalysisInput]) async throws -> [ScreenshotAnalysis] {
            callSizes.append(screenshots.count)
            activeCount += 1
            activeCountsAtStart.append(activeCount)
            maximumActiveCount = max(maximumActiveCount, activeCount)
            if isFirstWaveBlocked {
                await withCheckedContinuation { firstWaveWaiters.append($0) }
            }
            activeCount -= 1
            return screenshots.map {
                ScreenshotAnalysis(screenshotID: $0.id, ocrText: "batch text", caption: "batch caption")
            }
        }

        func releaseFirstWave() {
            isFirstWaveBlocked = false
            let waiters = firstWaveWaiters
            firstWaveWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private actor FailingOneScreenshotAnalyzer: ScreenshotAnalyzing {
        let failingID: UUID
        private(set) var callSizes: [Int] = []

        init(failingID: UUID) {
            self.failingID = failingID
        }

        func analyze(_ screenshots: [ScreenshotAnalysisInput]) async throws -> [ScreenshotAnalysis] {
            callSizes.append(screenshots.count)
            guard screenshots[0].id != failingID else { throw Failure() }
            return [
                ScreenshotAnalysis(
                    screenshotID: screenshots[0].id,
                    ocrText: "isolated text",
                    caption: "isolated caption"
                ),
            ]
        }

        private struct Failure: Error {}
    }

    private actor PrerequisiteRetryAnalyzer: ScreenshotAnalyzing {
        let failingID: UUID
        private(set) var firstWaveStartedCount = 0
        private(set) var firstWaveCancelledCount = 0
        private var isFirstWave = true
        private var failureWaiter: CheckedContinuation<Void, Never>?

        init(failingID: UUID) {
            self.failingID = failingID
        }

        func analyze(_ screenshots: [ScreenshotAnalysisInput]) async throws -> [ScreenshotAnalysis] {
            if isFirstWave {
                firstWaveStartedCount += 1
                if screenshots[0].id == failingID {
                    await withCheckedContinuation { failureWaiter = $0 }
                    isFirstWave = false
                    throw CodexAppServerError.requestedModelUnavailable(CodexScreenshotAnalysisService.model)
                }
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    firstWaveCancelledCount += 1
                    throw error
                }
            }
            return screenshots.map {
                ScreenshotAnalysis(screenshotID: $0.id, ocrText: "retry text", caption: "retry caption")
            }
        }

        func failFirstWave() -> Bool {
            guard let failureWaiter else { return false }
            self.failureWaiter = nil
            failureWaiter.resume()
            return true
        }
    }
#endif
