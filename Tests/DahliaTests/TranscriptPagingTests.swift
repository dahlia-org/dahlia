#if canImport(Testing)
    // swiftlint:disable file_length
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    // swiftlint:disable:next type_body_length
    struct TranscriptPagingTests {
        @Test
        func keysetPagingCoversTenThousandEqualTimestampsWithoutGaps() throws {
            let fixture = try makePagingFixture(segmentCount: 10_000)
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)

            var page = try repository.fetchTranscriptPage(
                forMeetingId: fixture.meetingId,
                direction: .latest,
                limit: 100
            )
            var loaded = page.segments

            while page.hasEarlier {
                let cursor = TranscriptPageCursor(segment: try #require(page.segments.first))
                page = try repository.fetchTranscriptPage(
                    forMeetingId: fixture.meetingId,
                    direction: .before(cursor),
                    limit: 100
                )
                loaded.insert(contentsOf: page.segments, at: 0)
            }

            #expect(loaded.count == 10_000)
            #expect(Set(loaded.map(\.id)).count == 10_000)
            #expect(loaded.map(\.id) == fixture.orderedIds)

            let middleCursor = TranscriptPageCursor(segment: loaded[4_999])
            let forward = try repository.fetchTranscriptPage(
                forMeetingId: fixture.meetingId,
                direction: .after(middleCursor),
                limit: 100
            )
            #expect(forward.segments.map(\.id) == Array(fixture.orderedIds[5_000 ..< 5_100]))
        }

        @Test
        func pagingFiltersUnconfirmedAndOtherMeetingsAndReportsPageEdges() throws {
            let fixture = try makePagingFixture(segmentCount: 3)
            let otherMeetingId = UUID.v7()
            let unconfirmedId = UUID.v7()
            try fixture.database.dbQueue.write { db in
                let vaultId = try #require(VaultRecord.fetchOne(db)?.id)
                let timestamp = Date(timeIntervalSince1970: 1_776_384_000)
                try MeetingRecord(
                    id: otherMeetingId,
                    vaultId: vaultId,
                    projectId: nil,
                    name: "Other",
                    createdAt: timestamp,
                    updatedAt: timestamp
                ).insert(db)
                try TranscriptSegmentRecord(
                    id: unconfirmedId,
                    meetingId: fixture.meetingId,
                    startTime: timestamp,
                    text: "preview",
                    translatedText: nil,
                    isConfirmed: false,
                    speakerLabel: "mic"
                ).insert(db)
                try TranscriptSegmentRecord(
                    id: .v7(),
                    meetingId: otherMeetingId,
                    startTime: timestamp,
                    text: "other meeting",
                    translatedText: nil,
                    isConfirmed: true,
                    speakerLabel: "mic"
                ).insert(db)
            }
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)

            let latest = try repository.fetchTranscriptPage(
                forMeetingId: fixture.meetingId,
                direction: .latest,
                limit: 2
            )
            #expect(latest.segments.map(\.id) == Array(fixture.orderedIds.suffix(2)))
            #expect(latest.hasEarlier)
            #expect(!latest.hasLater)

            let earlier = try repository.fetchTranscriptPage(
                forMeetingId: fixture.meetingId,
                direction: .before(TranscriptPageCursor(segment: try #require(latest.segments.first))),
                limit: 2
            )
            #expect(earlier.segments.map(\.id) == [fixture.orderedIds[0]])
            #expect(!earlier.hasEarlier)
            #expect(earlier.hasLater)

            let all = try repository.fetchTranscriptPage(
                forMeetingId: fixture.meetingId,
                direction: .latest,
                limit: .max
            )
            #expect(all.segments.map(\.id) == fixture.orderedIds)
            #expect(!all.segments.contains(where: { $0.id == unconfirmedId }))
        }

        @Test
        func storeKeepsAtMostThreeHundredConfirmedSegmentsAcrossPageShiftsAndLiveUpdates() async throws {
            let fixture = try makePagingFixture(segmentCount: 1_000)
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            let initialPage = try repository.fetchTranscriptPage(
                forMeetingId: fixture.meetingId,
                direction: .latest,
                limit: TranscriptStore.initialPageSize
            )
            let store = TranscriptStore()
            store.configurePaging(
                meetingId: fixture.meetingId,
                loader: TranscriptPageLoader(dbQueue: fixture.database.dbQueue),
                initialPage: initialPage
            )

            #expect(store.confirmedSegmentCount == 200)
            #expect(await store.loadEarlier())
            #expect(store.confirmedSegmentCount == 300)
            #expect(await store.loadEarlier())
            #expect(store.confirmedSegmentCount == 300)
            #expect(store.hasLaterSegments)
            #expect(await store.loadLater())
            #expect(store.confirmedSegmentCount == 300)

            _ = await store.reloadLatest()
            let liveStart = Date(timeIntervalSince1970: 1_776_400_000)
            for index in 0 ..< 1_000 {
                store.addSegment(TranscriptSegment(
                    id: deterministicUUID(index + 20_000),
                    startTime: liveStart.addingTimeInterval(Double(index)),
                    text: "live-\(index)",
                    isConfirmed: true
                ))
            }
            #expect(store.confirmedSegmentCount == TranscriptStore.maximumConfirmedSegmentCount)

            store.setFollowingLatest(false)
            let deferred = TranscriptSegment(
                startTime: liveStart.addingTimeInterval(2_000),
                text: "deferred",
                isConfirmed: true
            )
            store.addSegment(deferred)
            #expect(!store.segments.contains(where: { $0.id == deferred.id }))
            #expect(store.hasNewerSegments)
        }

        @Test
        func compactionReloadClearsPreviewThatCannotBeRestoredFromDatabase() async throws {
            let fixture = try makePagingFixture(segmentCount: 3)
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            let initialPage = try repository.fetchTranscriptPage(
                forMeetingId: fixture.meetingId,
                direction: .latest,
                limit: TranscriptStore.initialPageSize
            )
            let store = TranscriptStore()
            store.configurePaging(
                meetingId: fixture.meetingId,
                loader: TranscriptPageLoader(dbQueue: fixture.database.dbQueue),
                initialPage: initialPage
            )
            _ = store.updateUnconfirmedSegment(TranscriptSegment(
                startTime: .now,
                text: "stale preview",
                isConfirmed: false,
                speakerLabel: "mic"
            ), forSource: "mic")
            #expect(store.segments.contains(where: { !$0.isConfirmed }))

            #expect(await store.reloadLatestAfterUICompaction())
            #expect(!store.segments.contains(where: { !$0.isConfirmed }))
        }

        @Test
        func compactionReloadWaitsForAnInFlightPageInsteadOfBeingDropped() async throws {
            let fixture = try makePagingFixture(segmentCount: 1_000)
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            let store = TranscriptStore()
            store.configurePaging(
                meetingId: fixture.meetingId,
                loader: TranscriptPageLoader(dbQueue: fixture.database.dbQueue),
                initialPage: try repository.fetchTranscriptPage(
                    forMeetingId: fixture.meetingId,
                    direction: .latest,
                    limit: TranscriptStore.initialPageSize
                )
            )
            let databaseEntered = AsyncPagingGate()
            let releaseDatabase = DispatchSemaphore(value: 0)
            let blocker = Task.detached {
                try await fixture.database.dbQueue.write { _ in
                    Task { await databaseEntered.open() }
                    releaseDatabase.wait()
                }
            }
            await databaseEntered.wait()

            let earlier = Task { @MainActor in await store.loadEarlier() }
            await Task.yield()
            let reload = Task { @MainActor in await store.reloadLatestAfterUICompaction() }
            await Task.yield()
            #expect(store.isLoadingPage)
            releaseDatabase.signal()

            #expect(await earlier.value)
            #expect(await reload.value)
            try await blocker.value
            #expect(store.segments.filter(\.isConfirmed).map(\.id) == Array(fixture.orderedIds.suffix(200)))
            #expect(!store.hasLaterSegments)
        }

        @Test
        func latestPageMergePreservesLiveMutationThatArrivesDuringQuery() async throws {
            let fixture = try makePagingFixture(segmentCount: 3)
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            let store = TranscriptStore()
            store.configurePaging(
                meetingId: fixture.meetingId,
                loader: TranscriptPageLoader(dbQueue: fixture.database.dbQueue),
                initialPage: try repository.fetchTranscriptPage(
                    forMeetingId: fixture.meetingId,
                    direction: .latest,
                    limit: TranscriptStore.initialPageSize
                )
            )
            let databaseEntered = AsyncPagingGate()
            let releaseDatabase = DispatchSemaphore(value: 0)
            let blocker = Task.detached {
                try await fixture.database.dbQueue.write { _ in
                    Task { await databaseEntered.open() }
                    releaseDatabase.wait()
                }
            }
            await databaseEntered.wait()

            let reload = Task { @MainActor in await store.reloadLatest() }
            await Task.yield()
            let liveSegment = TranscriptSegment(
                startTime: Date(timeIntervalSince1970: 1_776_384_100),
                text: "live during query",
                isConfirmed: true
            )
            store.addSegment(liveSegment)
            releaseDatabase.signal()

            #expect(await reload.value)
            try await blocker.value
            #expect(store.segments.contains(where: { $0.id == liveSegment.id }))
        }

        @Test
        func latestPageMergePreservesDeferredLiveMutationThatIsNotYetPersisted() async throws {
            let fixture = try makePagingFixture(segmentCount: 3)
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            let store = TranscriptStore()
            let loader = TranscriptPageLoader(dbQueue: fixture.database.dbQueue)
            store.configurePaging(
                meetingId: fixture.meetingId,
                loader: loader,
                initialPage: try repository.fetchTranscriptPage(
                    forMeetingId: fixture.meetingId,
                    direction: .latest,
                    limit: TranscriptStore.initialPageSize
                )
            )
            store.setFollowingLatest(false)
            let databaseEntered = AsyncPagingGate()
            let releaseDatabase = DispatchSemaphore(value: 0)
            let blocker = Task.detached {
                try await fixture.database.dbQueue.write { _ in
                    Task { await databaseEntered.open() }
                    releaseDatabase.wait()
                }
            }
            await databaseEntered.wait()

            let reload = Task { @MainActor in await store.reloadLatest() }
            await Task.yield()
            let deferred = TranscriptSegment(
                startTime: Date(timeIntervalSince1970: 1_776_384_100),
                text: "deferred during query",
                isConfirmed: true
            )
            store.addSegment(deferred)
            releaseDatabase.signal()

            #expect(await reload.value)
            try await blocker.value
            #expect(store.segments.contains(where: { $0.id == deferred.id }))
            #expect(!store.hasNewerSegments)
        }

        @Test
        func deferredLiveTranslationIsPreservedWhenLatestPageIsOlder() async throws {
            let fixture = try makePagingFixture(segmentCount: 3)
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            let store = TranscriptStore()
            store.configurePaging(
                meetingId: fixture.meetingId,
                loader: TranscriptPageLoader(dbQueue: fixture.database.dbQueue),
                initialPage: try repository.fetchTranscriptPage(
                    forMeetingId: fixture.meetingId,
                    direction: .latest,
                    limit: TranscriptStore.initialPageSize
                )
            )
            store.setFollowingLatest(false)
            let deferred = TranscriptSegment(
                startTime: Date(timeIntervalSince1970: 1_776_384_100),
                text: "deferred",
                isConfirmed: true
            )
            store.addSegment(deferred)
            try await fixture.database.dbQueue.write { db in
                try TranscriptSegmentRecord(
                    id: deferred.id,
                    meetingId: fixture.meetingId,
                    startTime: deferred.startTime,
                    text: deferred.text,
                    translatedText: nil,
                    isConfirmed: true,
                    speakerLabel: deferred.speakerLabel
                ).insert(db)
            }
            #expect(await store.loadLater())
            store.updateTranslatedText(for: deferred.id, translatedText: "translated")
            #expect(store.segments.first(where: { $0.id == deferred.id })?.translatedText == "translated")

            #expect(await store.reloadLatest())
            #expect(store.segments.first(where: { $0.id == deferred.id })?.translatedText == "translated")
        }

        @Test
        func replacingPagingContextInvalidatesTheOldLoadingState() async throws {
            let fixture = try makePagingFixture(segmentCount: 3)
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            let store = TranscriptStore()
            store.configurePaging(
                meetingId: fixture.meetingId,
                loader: TranscriptPageLoader(dbQueue: fixture.database.dbQueue),
                initialPage: try repository.fetchTranscriptPage(
                    forMeetingId: fixture.meetingId,
                    direction: .latest,
                    limit: TranscriptStore.initialPageSize
                )
            )
            let databaseEntered = AsyncPagingGate()
            let releaseDatabase = DispatchSemaphore(value: 0)
            let blocker = Task.detached {
                try await fixture.database.dbQueue.write { _ in
                    Task { await databaseEntered.open() }
                    releaseDatabase.wait()
                }
            }
            await databaseEntered.wait()

            let staleReload = Task { @MainActor in await store.reloadLatest() }
            await Task.yield()
            #expect(store.isLoadingPage)
            store.attachPagingContext(
                meetingId: fixture.meetingId,
                loader: TranscriptPageLoader(dbQueue: fixture.database.dbQueue)
            )
            #expect(!store.isLoadingPage)
            releaseDatabase.signal()

            #expect(!(await staleReload.value))
            try await blocker.value
            #expect(await store.reloadLatest())
            #expect(!store.isLoadingPage)
        }

        @Test
        func fullTranscriptFormattingIncludesSegmentsOutsideTheInitialProjection() throws {
            let fixture = try makePagingFixture(segmentCount: 500)
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            let page = try repository.fetchTranscriptPage(
                forMeetingId: fixture.meetingId,
                direction: .latest,
                limit: TranscriptStore.initialPageSize
            )
            let summaryInput = try FullTranscriptLoader.summaryInput(
                meetingId: fixture.meetingId,
                dbQueue: fixture.database.dbQueue,
                recordingSessions: [],
                timeBase: page.segments[0].startTime
            )

            #expect(page.segments.count == 200)
            #expect(!page.segments.contains(where: { $0.text == "segment-0" }))
            #expect(summaryInput.segments.count == 500)
            #expect(summaryInput.text.contains("segment-0"))
            #expect(summaryInput.text.contains("segment-499"))
        }

        @Test
        // swiftlint:disable:next function_body_length
        func v22MigrationAddsPagingIndexWithoutChangingExistingRows() throws {
            let databaseURL = URL.temporaryDirectory
                .appending(path: UUID.v7().uuidString)
                .appendingPathExtension("sqlite")
            defer { try? FileManager.default.removeItem(at: databaseURL) }
            let segmentId = UUID.v7()
            let meetingId = UUID.v7()
            let queue = try DatabaseQueue(path: databaseURL.path)

            try queue.write { db in
                try db.execute(
                    sql: """
                    CREATE TABLE transcript_segments (
                        id BLOB PRIMARY KEY,
                        meetingId BLOB NOT NULL,
                        sessionId BLOB,
                        startTime DATETIME NOT NULL,
                        endTime DATETIME,
                        text TEXT NOT NULL,
                        translatedText TEXT,
                        isConfirmed BOOLEAN NOT NULL DEFAULT 0,
                        speakerLabel TEXT
                    )
                    """
                )
                try db.create(table: "grdb_migrations") { table in
                    table.column("identifier", .text).primaryKey()
                }
                for migration in Self.migrationsBeforeV22 {
                    try db.execute(
                        sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                        arguments: [migration]
                    )
                }
                try db.execute(
                    sql: """
                    INSERT INTO transcript_segments
                        (id, meetingId, startTime, text, isConfirmed)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [segmentId, meetingId, Date.now, "preserved", true]
                )
            }

            let migrated = try AppDatabaseManager(path: databaseURL.path)
            let result = try migrated.dbQueue.read { db in
                let indexColumns = try String.fetchAll(
                    db,
                    sql: """
                    SELECT name FROM pragma_index_info(
                        'transcript_segments_on_meetingId_isConfirmed_startTime_id'
                    )
                    ORDER BY seqno
                    """
                )
                let text = try String.fetchOne(
                    db,
                    sql: "SELECT text FROM transcript_segments WHERE id = ?",
                    arguments: [segmentId]
                )
                return (indexColumns, text)
            }

            #expect(result.0 == ["meetingId", "isConfirmed", "startTime", "id"])
            #expect(result.1 == "preserved")
        }

        private static let migrationsBeforeV22 = [
            "v3_googleDriveFolderSchema",
            "v4_instructionsSchema",
            "v5_summaryGoogleFileId",
            "v6_transcriptSegmentTranslation",
            "v7_normalizeLegacyMeetingStatus",
            "v8_recordingSessions",
            "v9_summaryDocument",
            "v10_batchTranscription",
            "v11_batchAudioStorageLocation",
            "v12_batchTranscriptionDiscard",
            "v13_summaryVaultRelativePath",
            "v14_projectDescription",
            "v15_calendarEventIdentity",
            "v16_calendarEventURL",
            "v17_calendarEventIntegrity",
            "v18_segmentedRecordingAudio",
            "v19_summaryExports",
            "v20_meetingDescription",
            "v21_removeLegacySummaryColumns",
        ]
    }

    private struct PagingFixture {
        let database: AppDatabaseManager
        let meetingId: UUID
        let orderedIds: [UUID]
    }

    @MainActor
    private func makePagingFixture(segmentCount: Int) throws -> PagingFixture {
        let database = try AppDatabaseManager(path: ":memory:")
        let vault = VaultRecord(
            id: .v7(),
            path: URL.temporaryDirectory.path,
            name: "Paging Test",
            createdAt: .now,
            lastOpenedAt: .now
        )
        let meetingId = UUID.v7()
        let timestamp = Date(timeIntervalSince1970: 1_776_384_000)
        let orderedIds = (0 ..< segmentCount).map(deterministicUUID)

        try database.dbQueue.write { db in
            try vault.insert(db)
            try MeetingRecord(
                id: meetingId,
                vaultId: vault.id,
                projectId: nil,
                name: "Large transcript",
                createdAt: timestamp,
                updatedAt: timestamp
            ).insert(db)
            for (index, id) in orderedIds.enumerated() {
                try TranscriptSegmentRecord(
                    id: id,
                    meetingId: meetingId,
                    startTime: timestamp,
                    text: "segment-\(index)",
                    translatedText: nil,
                    isConfirmed: true,
                    speakerLabel: "mic"
                ).insert(db)
            }
        }
        return PagingFixture(database: database, meetingId: meetingId, orderedIds: orderedIds)
    }

    private func deterministicUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-7000-8000-%012llx", value))!
    }

    private actor AsyncPagingGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            isOpen = true
            let continuations = waiters
            waiters.removeAll()
            continuations.forEach { $0.resume() }
        }
    }
#endif
