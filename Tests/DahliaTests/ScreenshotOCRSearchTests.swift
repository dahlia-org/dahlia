import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    // swiftlint:disable:next type_body_length
    struct ScreenshotOCRSearchTests {
        @Test
        func ranksOCRThenMixedThenCaptionAcrossPages() async throws {
            let ocrID = UUID.v7()
            let mixedID = UUID.v7()
            let captionID = UUID.v7()
            let database = try AppDatabaseManager(
                path: ":memory:",
                screenshotAnalyzer: MappedScreenshotAnalyzer(values: [
                    ocrID: ("alpha beta in detected text", "unrelated description"),
                    mixedID: ("alpha in detected text", "beta in image description"),
                    captionID: ("unrelated detected text", "alpha beta in image description"),
                ])
            )
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                for (id, capturedAt) in [
                    (ocrID, Date(timeIntervalSince1970: 100)),
                    (mixedID, Date(timeIntervalSince1970: 200)),
                    (captionID, Date(timeIntervalSince1970: 300)),
                ] {
                    try MeetingScreenshotRecord(
                        id: id,
                        meetingId: meeting.id,
                        sessionId: nil,
                        capturedAt: capturedAt,
                        imageData: Data([1]),
                        mimeType: "image/png"
                    ).insert(db)
                }
            }
            await database.searchIndexer.drain()

            var cursor: ScreenshotSearchCursor?
            var results: [ScreenshotSearchResult] = []
            repeat {
                let page = try await MeetingRepository.searchScreenshotPage(
                    vaultID: vault.id,
                    criteria: MeetingSearchCriteria(text: "alpha beta"),
                    after: cursor,
                    limit: 1,
                    dbQueue: database.dbQueue
                )
                results += page.items
                cursor = page.nextCursor
            } while cursor != nil

            #expect(results.map(\.id) == [ocrID, mixedID, captionID])
            #expect(results.map { $0.matches.map(\.source) } == [[.ocr], [.ocr, .caption], [.caption]])
        }

        @Test
        func returnsBothMatchSourcesWithRelevantLongSnippets() async throws {
            let screenshotID = UUID.v7()
            let captionOnlyID = UUID.v7()
            let prefix = "BEGIN " + String(repeating: "before ", count: 40)
            let suffix = String(repeating: " after", count: 40) + " END"
            let database = try AppDatabaseManager(
                path: ":memory:",
                screenshotAnalyzer: MappedScreenshotAnalyzer(values: [
                    screenshotID: (
                        "\(prefix)target phrase in detected text\(suffix)",
                        "\(prefix)target phrase in image description\(suffix)"
                    ),
                    captionOnlyID: ("unrelated detected text", "target phrase in a newer description"),
                ])
            )
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try MeetingScreenshotRecord(
                    id: screenshotID,
                    meetingId: meeting.id,
                    sessionId: nil,
                    capturedAt: .now,
                    imageData: Data([1]),
                    mimeType: "image/png"
                ).insert(db)
                try MeetingScreenshotRecord(
                    id: captionOnlyID,
                    meetingId: meeting.id,
                    sessionId: nil,
                    capturedAt: .now.addingTimeInterval(60),
                    imageData: Data([2]),
                    mimeType: "image/png"
                ).insert(db)
            }
            await database.searchIndexer.drain()

            let result = try #require(try await MeetingRepository.searchScreenshotPage(
                vaultID: vault.id,
                criteria: MeetingSearchCriteria(text: "target phrase"),
                limit: 20,
                dbQueue: database.dbQueue
            ).items.first)

            #expect(result.matches.map(\.source) == [.ocr, .caption])
            #expect(result.matches.allSatisfy { $0.snippet.contains("target phrase") })
            #expect(result.matches.allSatisfy { $0.snippet.count <= 180 })
            #expect(result.matches.allSatisfy { !$0.snippet.hasPrefix("BEGIN") })
        }

        @Test
        func locatesNormalizedJapaneseTokenInLongOCRText() async throws {
            let screenshotID = UUID.v7()
            let prefix = "BEGIN " + String(repeating: "前の文章", count: 50)
            let database = try AppDatabaseManager(
                path: ":memory:",
                screenshotAnalyzer: MappedScreenshotAnalyzer(values: [
                    screenshotID: ("\(prefix)会議で話した内容", "関係のない説明"),
                ])
            )
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
                try MeetingScreenshotRecord(
                    id: screenshotID,
                    meetingId: meeting.id,
                    sessionId: nil,
                    capturedAt: .now,
                    imageData: Data([1]),
                    mimeType: "image/png"
                ).insert(db)
            }
            await database.searchIndexer.drain()

            let result = try #require(try await MeetingRepository.searchScreenshotPage(
                vaultID: vault.id,
                criteria: MeetingSearchCriteria(text: "話す"),
                limit: 20,
                dbQueue: database.dbQueue
            ).items.first)

            let snippet = try #require(result.matches.first?.snippet)
            #expect(snippet.contains("話した"))
            #expect(!snippet.hasPrefix("BEGIN"))
        }

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
        func recordingPauseCancelsInFlightOCRAndRequeuesIt() async throws {
            let analyzer = SlowScreenshotAnalyzer()
            let database = try AppDatabaseManager(path: ":memory:", screenshotAnalyzer: analyzer)
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            try await database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
            }
            await database.searchIndexer.drain()
            await database.searchIndexer.start()
            let screenshot = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: meeting.id,
                sessionId: nil,
                capturedAt: .now,
                imageData: Data([1]),
                mimeType: "image/png"
            )
            try await database.dbQueue.write { db in try screenshot.insert(db) }
            #expect(await pollUntil { await analyzer.didStart })

            await database.searchIndexer.pauseForRecording()

            let state = try await database.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT screenshots.ocrText, search_index_jobs.status
                    FROM screenshots
                    JOIN search_index_jobs ON search_index_jobs.targetKey = screenshots.id
                    WHERE screenshots.id = ? AND search_index_jobs.targetKind = 'screenshotAnalysis'
                    """,
                    arguments: [screenshot.id]
                )
            }
            #expect(state?["ocrText"] as String? == nil)
            #expect(state?["status"] as String? == "pending")
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

        @Test
        func analyzesScreenshotsInBatchesOfFour() async throws {
            let analyzer = RecordingScreenshotAnalyzer()
            let database = try AppDatabaseManager(path: ":memory:", screenshotAnalyzer: analyzer)
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            let screenshots = (0 ..< 5).map { index in
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

            await database.searchIndexer.drain()

            #expect(await analyzer.batchSizes == [4, 1])
            let indexedCount = try await database.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM screenshots WHERE ocrText IS NOT NULL AND caption IS NOT NULL"
                ) ?? 0
            }
            #expect(indexedCount == 5)
        }

        @Test
        func batchFailureIsolatesTheFailingScreenshot() async throws {
            let failingID = UUID.v7()
            let analyzer = BatchIsolatingScreenshotAnalyzer(failingID: failingID)
            let database = try AppDatabaseManager(path: ":memory:", screenshotAnalyzer: analyzer)
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            let screenshots = [failingID] + (0 ..< 3).map { _ in UUID.v7() }
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
                    )
                )
            }
            #expect(state.0 == 3)
            #expect(state.1 == 1)
            #expect(await analyzer.batchSizes == [4, 1, 1, 1, 1])
        }

        @Test
        func unavailableRequiredModelBacksOffTheEntireScreenshotQueue() async throws {
            let analyzer = UnavailableThenSuccessfulScreenshotAnalyzer()
            let database = try AppDatabaseManager(path: ":memory:", screenshotAnalyzer: analyzer)
            let vault = makeVault()
            let meeting = makeMeeting(vaultID: vault.id)
            let screenshots = (0 ..< 5).map { index in
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
                try db.execute(
                    sql: "UPDATE search_index_jobs SET attempts = 3 WHERE targetKind = 'screenshotAnalysis'"
                )
            }

            await database.searchIndexer.drain()
            let deferred = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM search_index_jobs WHERE targetKind = 'screenshotAnalysis' AND status = 'pending'"
                    ) ?? 0,
                    Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM search_index_jobs WHERE targetKind = 'screenshotAnalysis' AND attempts = 3"
                    ) ?? 0,
                    Date.fetchOne(
                        db,
                        sql: "SELECT MIN(availableAt) FROM search_index_jobs WHERE targetKind = 'screenshotAnalysis'"
                    )
                )
            }
            #expect(deferred.0 == 5)
            #expect(deferred.1 == 5)
            #expect((deferred.2 ?? .distantPast) > .now)
            #expect(await analyzer.callCount == 1)

            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE search_index_jobs SET availableAt = ? WHERE targetKind = 'screenshotAnalysis'",
                    arguments: [Date.distantPast]
                )
            }
            await database.searchIndexer.drain()

            let storedCount = try await database.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM screenshots WHERE ocrText = 'retry text' AND caption = 'retry caption'"
                ) ?? 0
            }
            #expect(storedCount == 5)
            #expect(await analyzer.callCount == 3)
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
            let reset = try await database.dbQueue.read { db in
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
                try vault.insert(db)
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

    private struct MappedScreenshotAnalyzer: ScreenshotAnalyzing {
        let values: [UUID: (ocr: String, caption: String)]

        func analyze(_ screenshots: [ScreenshotAnalysisInput]) async throws -> [ScreenshotAnalysis] {
            screenshots.map { screenshot in
                let value = values[screenshot.id] ?? ("", "")
                return ScreenshotAnalysis(
                    screenshotID: screenshot.id,
                    ocrText: value.ocr,
                    caption: value.caption
                )
            }
        }
    }

    private actor SlowScreenshotAnalyzer: ScreenshotAnalyzing {
        private(set) var didStart = false

        func analyze(_: [ScreenshotAnalysisInput]) async throws -> [ScreenshotAnalysis] {
            didStart = true
            try await Task.sleep(for: .seconds(60))
            return []
        }
    }

    private struct FailingScreenshotAnalyzer: ScreenshotAnalyzing {
        func analyze(_: [ScreenshotAnalysisInput]) async throws -> [ScreenshotAnalysis] { throw Failure() }
        private struct Failure: Error {}
    }

    private actor RecordingScreenshotAnalyzer: ScreenshotAnalyzing {
        private(set) var batchSizes: [Int] = []

        func analyze(_ screenshots: [ScreenshotAnalysisInput]) async throws -> [ScreenshotAnalysis] {
            batchSizes.append(screenshots.count)
            return screenshots.map {
                ScreenshotAnalysis(screenshotID: $0.id, ocrText: "batch text", caption: "batch caption")
            }
        }
    }

    private actor BatchIsolatingScreenshotAnalyzer: ScreenshotAnalyzing {
        let failingID: UUID
        private(set) var batchSizes: [Int] = []

        init(failingID: UUID) {
            self.failingID = failingID
        }

        func analyze(_ screenshots: [ScreenshotAnalysisInput]) async throws -> [ScreenshotAnalysis] {
            batchSizes.append(screenshots.count)
            guard screenshots.count == 1, screenshots[0].id != failingID else { throw Failure() }
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

    private actor UnavailableThenSuccessfulScreenshotAnalyzer: ScreenshotAnalyzing {
        private(set) var callCount = 0

        func analyze(_ screenshots: [ScreenshotAnalysisInput]) async throws -> [ScreenshotAnalysis] {
            callCount += 1
            if callCount == 1 {
                throw CodexAppServerError.requestedModelUnavailable(CodexScreenshotAnalysisService.model)
            }
            return screenshots.map {
                ScreenshotAnalysis(screenshotID: $0.id, ocrText: "retry text", caption: "retry caption")
            }
        }
    }
#endif
