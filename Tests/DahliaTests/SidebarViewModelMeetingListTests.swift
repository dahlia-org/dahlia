import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    // swiftlint:disable:next type_body_length
    struct SidebarViewModelMeetingListTests {
        @Test(.timeLimit(.minutes(3)))
        func loadsMeetingsInFiftyItemBatches() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer {
                fixture.stop()
            }
            try await fixture.manager.dbQueue.write { db in
                for index in 0 ..< 51 {
                    try MeetingRecord(
                        id: .v7(),
                        vaultId: fixture.vault.id,
                        projectId: nil,
                        name: "Meeting \(index)",
                        createdAt: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(index)),
                        updatedAt: .now
                    ).insert(db)
                }
            }
            let viewModel = fixture.makeViewModel()
            defer {
                viewModel.setAppDatabase(nil)
            }

            #expect(await waitUntil {
                viewModel.isMeetingListLoaded && viewModel.meetingSidebarItems.count == 50
            })
            #expect(viewModel.hasMoreMeetings)

            viewModel.loadMoreDisplayedMeetings()

            #expect(viewModel.isMeetingListLoadingMore)
            #expect(await waitUntil {
                viewModel.meetingSidebarItems.count == 51 && !viewModel.isMeetingListLoadingMore
            })
            #expect(!viewModel.hasMoreMeetings)
        }

        @Test(.timeLimit(.minutes(3)))
        func refreshesMeetingRowsLoadedAfterInitialPage() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer {
                fixture.stop()
            }
            let olderMeetingID = UUID.v7()
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            try await fixture.manager.dbQueue.write { db in
                try MeetingRecord(
                    id: olderMeetingID,
                    vaultId: fixture.vault.id,
                    projectId: nil,
                    name: "Older meeting",
                    createdAt: start,
                    updatedAt: start
                ).insert(db)
                for index in 1 ... 50 {
                    try insertMeeting(
                        vaultId: fixture.vault.id,
                        name: "Meeting \(index)",
                        createdAt: start.addingTimeInterval(TimeInterval(index)),
                        in: db
                    )
                }
            }
            let viewModel = fixture.makeViewModel()
            defer {
                viewModel.setAppDatabase(nil)
            }
            #expect(await waitUntil { viewModel.meetingSidebarItems.count == 50 })

            viewModel.loadMoreDisplayedMeetings()
            #expect(await waitUntil {
                viewModel.meetingSidebarItems.count == 51 && !viewModel.isMeetingListLoadingMore
            })

            try await fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE meetings
                    SET status = ?, duration = ?
                    WHERE id = ?
                    """,
                    arguments: [MeetingStatus.ready, 42.0, olderMeetingID]
                )
            }

            #expect(await waitUntil {
                let item = viewModel.meetingSidebarItems.first { $0.id == olderMeetingID }
                return item?.status == .ready && item?.duration == 42
            })
        }

        @Test(.timeLimit(.minutes(3)))
        func debouncesSearchAndIncludesTranscriptMatches() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer {
                fixture.stop()
            }
            let metadataMeetingID = UUID.v7()
            let transcriptOnlyMeetingID = UUID.v7()
            try await fixture.manager.dbQueue.write { db in
                try MeetingRecord(
                    id: metadataMeetingID,
                    vaultId: fixture.vault.id,
                    projectId: nil,
                    name: "Needle planning",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try MeetingRecord(
                    id: transcriptOnlyMeetingID,
                    vaultId: fixture.vault.id,
                    projectId: nil,
                    name: "Transcript only",
                    createdAt: .now.addingTimeInterval(-1),
                    updatedAt: .now
                ).insert(db)
                try TranscriptSegmentRecord(
                    id: .v7(),
                    meetingId: transcriptOnlyMeetingID,
                    startTime: .now,
                    text: "Needle",
                    translatedText: nil,
                    isConfirmed: true
                ).insert(db)
            }
            await fixture.manager.searchIndexer.drain()
            let viewModel = fixture.makeViewModel()
            defer {
                viewModel.setAppDatabase(nil)
            }
            #expect(await waitUntil { viewModel.isMeetingListLoaded })

            viewModel.updateMeetingSearchQuery("Needle")

            #expect(viewModel.isSearchingMeetings)
            #expect(!viewModel.isMeetingSearchLoaded)
            #expect(await waitUntil {
                viewModel.isMeetingSearchLoaded
                    && viewModel.meetingSearchItems.map(\.id) == [metadataMeetingID, transcriptOnlyMeetingID]
            })
            #expect(viewModel.meetingSearchItems.last?.searchMatchContext?.kind == .transcript)

            viewModel.updateMeetingSearchQuery("")

            #expect(!viewModel.isSearchingMeetings)
            #expect(viewModel.displayedMeetingItems.count == 2)
        }

        @Test(.timeLimit(.minutes(3)))
        func searchesBeyondInitialPageAndPaginatesMatches() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer {
                fixture.stop()
            }
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            try await fixture.manager.dbQueue.write { db in
                for index in 0 ..< 51 {
                    try insertMeeting(
                        vaultId: fixture.vault.id,
                        name: "Needle \(index)",
                        createdAt: start.addingTimeInterval(TimeInterval(index)),
                        in: db
                    )
                }
                for index in 0 ..< 60 {
                    try insertMeeting(
                        vaultId: fixture.vault.id,
                        name: "Recent \(index)",
                        createdAt: start.addingTimeInterval(1000 + TimeInterval(index)),
                        in: db
                    )
                }
            }
            await fixture.manager.searchIndexer.drain()
            let viewModel = fixture.makeViewModel()
            defer {
                viewModel.setAppDatabase(nil)
            }
            #expect(await waitUntil { viewModel.meetingSidebarItems.count == 50 })

            viewModel.updateMeetingSearchQuery("Needle")

            #expect(await waitUntil {
                viewModel.isMeetingSearchLoaded
                    && viewModel.meetingSearchItems.count == 50
                    && viewModel.hasMoreMeetingSearchResults
            })

            viewModel.loadMoreDisplayedMeetings()

            #expect(await waitUntil {
                viewModel.meetingSearchItems.count == 51
                    && !viewModel.isMeetingSearchLoadingMore
            })
            #expect(!viewModel.hasMoreMeetingSearchResults)
        }

        @Test(.timeLimit(.minutes(3)))
        func rapidSearchChangePublishesOnlyLatestQuery() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer {
                fixture.stop()
            }
            try await fixture.manager.dbQueue.write { db in
                try insertMeeting(vaultId: fixture.vault.id, name: "Alpha planning", in: db)
                try insertMeeting(vaultId: fixture.vault.id, name: "Beta planning", in: db)
            }
            await fixture.manager.searchIndexer.drain()
            let viewModel = fixture.makeViewModel()
            defer {
                viewModel.setAppDatabase(nil)
            }
            #expect(await waitUntil { viewModel.isMeetingListLoaded })

            viewModel.updateMeetingSearchQuery("Alpha")
            viewModel.updateMeetingSearchQuery("Beta")

            #expect(await waitUntil {
                viewModel.isMeetingSearchLoaded
                    && viewModel.meetingSearchItems.map(\.meetingName) == ["Beta planning"]
            })
            #expect(viewModel.meetingSearchQuery == "Beta")
        }

        @Test(.timeLimit(.minutes(3)))
        func activeSearchRefreshesWhenTheIndexCatchesUp() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer {
                fixture.stop()
            }
            let meetingID = UUID.v7()
            try await fixture.manager.dbQueue.write { db in
                try MeetingRecord(
                    id: meetingID,
                    vaultId: fixture.vault.id,
                    projectId: nil,
                    name: "Original target",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            await fixture.manager.searchIndexer.drain()
            let viewModel = fixture.makeViewModel()
            defer {
                viewModel.setAppDatabase(nil)
            }
            #expect(await waitUntil { viewModel.isMeetingListLoaded })
            let initialRevision = try await fixture.manager.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT indexRevision FROM search_index_state WHERE indexKind = 'fts'"
                ) ?? 0
            }
            #expect(await waitUntil(timeout: .seconds(5)) { viewModel.searchIndexRevision == initialRevision })
            viewModel.updateMeetingSearchQuery("Original")
            #expect(await waitUntil(timeout: .seconds(5)) { viewModel.meetingSearchItems.map(\.id) == [meetingID] })

            try await fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE meetings SET name = ?, updatedAt = ? WHERE id = ?",
                    arguments: ["Renamed target", Date(), meetingID]
                )
            }
            await fixture.manager.searchIndexer.drain()
            let updatedRevision = try await fixture.manager.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT indexRevision FROM search_index_state WHERE indexKind = 'fts'"
                ) ?? 0
            }
            #expect(updatedRevision > initialRevision)
            let currentPage = try await MeetingRepository.searchMeetingSidebarPage(
                vaultId: fixture.vault.id,
                query: "Original",
                limit: 20,
                dbQueue: fixture.manager.dbQueue
            )
            #expect(currentPage.items.isEmpty)

            #expect(await waitUntil(timeout: .seconds(5)) {
                viewModel.searchIndexRevision == updatedRevision
            })
            #expect(await waitUntil(timeout: .seconds(5)) {
                viewModel.isMeetingSearchLoaded && viewModel.meetingSearchItems.isEmpty
            })
        }

        @Test(.timeLimit(.minutes(3)))
        func selectedMeetingOutsideInitialPageStaysAvailableAndObservesChanges() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer {
                fixture.stop()
            }
            let selectedID = UUID.v7()
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            try await fixture.manager.dbQueue.write { db in
                try MeetingRecord(
                    id: selectedID,
                    vaultId: fixture.vault.id,
                    projectId: nil,
                    name: "Old meeting",
                    createdAt: start,
                    updatedAt: start
                ).insert(db)
                for index in 1 ... 50 {
                    try insertMeeting(
                        vaultId: fixture.vault.id,
                        name: "Meeting \(index)",
                        createdAt: start.addingTimeInterval(TimeInterval(index)),
                        in: db
                    )
                }
            }
            let viewModel = fixture.makeViewModel()
            defer {
                viewModel.setAppDatabase(nil)
            }
            #expect(await waitUntil { viewModel.meetingSidebarItems.count == 50 })

            viewModel.selectMeeting(selectedID)

            #expect(await waitUntil {
                viewModel.selectedMeetingDetail?.meetingId == selectedID
                    && viewModel.selectedMeetingOutsideDisplayedItems?.meetingId == selectedID
            })

            try MeetingRepository(dbQueue: fixture.manager.dbQueue)
                .renameMeeting(id: selectedID, newName: "Renamed meeting")
            #expect(await waitUntil {
                viewModel.selectedMeetingDetail?.meetingName == "Renamed meeting"
            })

            viewModel.selectedMeetingIds.insert(UUID.v7())
            #expect(viewModel.selectedMeetingDetail == nil)
        }

        @Test(.timeLimit(.minutes(3)))
        func capsMaterializedMeetingListAndDefersChatCatalog() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer {
                fixture.stop()
            }
            try await fixture.manager.dbQueue.write { db in
                for index in 0 ... SidebarViewModel.maximumVisibleMeetings {
                    try insertMeeting(
                        vaultId: fixture.vault.id,
                        name: "Meeting \(index)",
                        createdAt: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(index)),
                        in: db
                    )
                }
            }
            let viewModel = fixture.makeViewModel()
            defer {
                viewModel.setAppDatabase(nil)
            }
            #expect(await waitUntil { viewModel.meetingSidebarItems.count == SidebarViewModel.meetingPageSize })
            #expect(viewModel.meetingReferences.isEmpty)
            #expect(!viewModel.isMeetingCatalogRequested)

            while viewModel.hasMoreMeetings {
                viewModel.loadMoreDisplayedMeetings()
                #expect(await waitUntil { !viewModel.isMeetingListLoadingMore })
            }

            #expect(viewModel.meetingSidebarItems.count == SidebarViewModel.maximumVisibleMeetings)
            #expect(viewModel.isMeetingListLimited)

            viewModel.loadMeetingReferencesIfNeeded()

            #expect(await waitUntil {
                viewModel.isMeetingCatalogLoaded
                    && viewModel.meetingReferences.count == SidebarViewModel.maximumVisibleMeetings + 1
            })
        }

        @Test(.timeLimit(.minutes(3)))
        func loadsFiveProjectMeetingsThenTenMore() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer { fixture.stop() }
            let projectID = UUID.v7()
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            try await fixture.manager.dbQueue.write { db in
                try ProjectRecord(
                    id: projectID,
                    vaultId: fixture.vault.id,
                    parentProjectId: nil,
                    name: "Project",
                    createdAt: .now,
                    projectType: .undefined
                ).insert(db)
                for index in 0 ..< 16 {
                    try insertMeeting(
                        vaultId: fixture.vault.id,
                        projectId: projectID,
                        name: "Meeting \(index)",
                        createdAt: start.addingTimeInterval(TimeInterval(index)),
                        in: db
                    )
                }
            }
            let viewModel = fixture.makeViewModel()
            defer { viewModel.setAppDatabase(nil) }
            let key = MeetingProjectKey.project(projectID)

            #expect(viewModel.projectMeetingObservation == nil)
            #expect(!viewModel.isProjectMeetingProjectionLoaded)
            viewModel.setProjectMeetingProjectionNeeded(true)
            #expect(await waitUntil {
                viewModel.isProjectMeetingProjectionLoaded
                    && viewModel.projectMeetingItemsByKey[key]?.count == 5
            })

            viewModel.loadMoreProjectMeetings(key: key)

            #expect(await waitUntil {
                viewModel.projectMeetingItemsByKey[key]?.count == 15
                    && !viewModel.projectMeetingLoadingKeys.contains(key)
            })
            #expect(viewModel.projectMeetingHasMoreByKey[key] == true)

            try await fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM meetings WHERE projectId = ? AND name = ?",
                    arguments: [projectID, "Meeting 8"]
                )
            }
            #expect(await waitUntil {
                viewModel.projectMeetingItemsByKey[key]?.count == 15
                    && viewModel.projectMeetingItemsByKey[key]?.contains(where: { $0.meetingName == "Meeting 0" }) == true
                    && viewModel.projectMeetingHasMoreByKey[key] == false
            })

            try await fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM meetings WHERE projectId = ? AND createdAt < ?",
                    arguments: [projectID, start.addingTimeInterval(10)]
                )
            }
            #expect(await waitUntil {
                viewModel.projectMeetingItemsByKey[key]?.count == 6
                    && viewModel.projectMeetingHasMoreByKey[key] == false
            })
        }

        @Test(.timeLimit(.minutes(3)))
        func ordersProjectsByNameAndKeepsUnassignedLast() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer { fixture.stop() }
            let alphaProjectID = UUID.v7()
            let zuluProjectID = UUID.v7()
            let now = Date.now
            try await fixture.manager.dbQueue.write { db in
                try ProjectRecord(
                    id: alphaProjectID,
                    vaultId: fixture.vault.id,
                    parentProjectId: nil,
                    name: "Alpha",
                    createdAt: now,
                    projectType: .undefined
                ).insert(db)
                try ProjectRecord(
                    id: zuluProjectID,
                    vaultId: fixture.vault.id,
                    parentProjectId: nil,
                    name: "Zulu",
                    createdAt: now,
                    projectType: .undefined
                ).insert(db)
                try insertMeeting(
                    vaultId: fixture.vault.id,
                    projectId: alphaProjectID,
                    name: "Alpha meeting",
                    createdAt: now.addingTimeInterval(-60),
                    in: db
                )
                try insertMeeting(
                    vaultId: fixture.vault.id,
                    projectId: zuluProjectID,
                    name: "Zulu newest",
                    createdAt: now,
                    in: db
                )
                try insertMeeting(
                    vaultId: fixture.vault.id,
                    name: "Newer unassigned meeting",
                    createdAt: now.addingTimeInterval(60),
                    in: db
                )
            }
            let viewModel = fixture.makeViewModel()
            defer { viewModel.setAppDatabase(nil) }
            viewModel.setProjectMeetingProjectionNeeded(true)

            #expect(await waitUntil {
                viewModel.isProjectMeetingProjectionLoaded
                    && viewModel.isProjectCatalogLoaded
                    && viewModel.projectMeetingGroups.count == 3
            })
            #expect(viewModel.projectMeetingGroups.map(\.key) == [
                .project(alphaProjectID), .project(zuluProjectID), .unassigned,
            ])
        }

        @Test(.timeLimit(.minutes(3)))
        func capsProjectMeetingsAtFiveHundred() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer { fixture.stop() }
            let projectID = UUID.v7()
            try await fixture.manager.dbQueue.write { db in
                try ProjectRecord(
                    id: projectID,
                    vaultId: fixture.vault.id,
                    parentProjectId: nil,
                    name: "Project",
                    createdAt: .now,
                    projectType: .undefined
                ).insert(db)
                for index in 0 ... SidebarViewModel.maximumVisibleMeetings {
                    try insertMeeting(
                        vaultId: fixture.vault.id,
                        projectId: projectID,
                        name: "Meeting \(index)",
                        createdAt: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(index)),
                        in: db
                    )
                }
            }
            let viewModel = fixture.makeViewModel()
            defer { viewModel.setAppDatabase(nil) }
            let key = MeetingProjectKey.project(projectID)
            viewModel.setProjectMeetingProjectionNeeded(true)
            #expect(await waitUntil { viewModel.isProjectMeetingProjectionLoaded })

            let loaded = try await fixture.manager.dbQueue.read { db in
                try MeetingRepository.fetchMeetingProjectPage(
                    key: key,
                    vaultId: fixture.vault.id,
                    after: nil,
                    limit: SidebarViewModel.maximumVisibleMeetings - 5,
                    in: db
                ).items
            }
            viewModel.projectMeetingItemsByKey[key] = loaded
            viewModel.projectMeetingHasMoreByKey[key] = true
            viewModel.loadMoreProjectMeetings(key: key)

            #expect(await waitUntil {
                !viewModel.projectMeetingLoadingKeys.contains(key)
                    && viewModel.projectMeetingItemsByKey[key]?.count == SidebarViewModel.maximumVisibleMeetings
            })
            #expect(viewModel.projectMeetingLimitedKeys.contains(key))
            #expect(viewModel.projectMeetingHasMoreByKey[key] == false)
        }

        private func waitUntil(
            timeout: Duration = testPollTimeout,
            _ predicate: @MainActor () -> Bool
        ) async -> Bool {
            await pollUntil(timeout: timeout) { predicate() }
        }
    }

    @MainActor
    struct SidebarViewModelMeetingSearchTests {
        @Test(.timeLimit(.minutes(3)))
        func searchesWithFiltersWithoutFreeTextAndClearsThemTogether() async throws {
            let fixture = try SidebarViewModelMeetingListFixture()
            defer {
                fixture.stop()
            }
            let boundary = Date(timeIntervalSince1970: 1_800_000_000)
            let includedID = UUID.v7()
            try await fixture.manager.dbQueue.write { db in
                try MeetingRecord(
                    id: includedID,
                    vaultId: fixture.vault.id,
                    projectId: nil,
                    name: "Included",
                    createdAt: boundary,
                    updatedAt: boundary
                ).insert(db)
                try MeetingRecord(
                    id: .v7(),
                    vaultId: fixture.vault.id,
                    projectId: nil,
                    name: "Excluded",
                    createdAt: boundary.addingTimeInterval(-1),
                    updatedAt: boundary
                ).insert(db)
            }
            let viewModel = fixture.makeViewModel()
            defer {
                viewModel.setAppDatabase(nil)
            }
            #expect(await waitUntil { viewModel.isMeetingListLoaded })

            viewModel.updateMeetingSearchCriteria(MeetingSearchCriteria(startDate: boundary))

            #expect(viewModel.isSearchingMeetings)
            #expect(await waitUntil {
                viewModel.isMeetingSearchLoaded && viewModel.meetingSearchItems.map(\.id) == [includedID]
            })

            viewModel.updateMeetingSearchCriteria(MeetingSearchCriteria())

            #expect(!viewModel.isSearchingMeetings)
            #expect(viewModel.displayedMeetingItems.count == 2)
        }

        private func waitUntil(
            timeout: Duration = testPollTimeout,
            _ predicate: @MainActor () -> Bool
        ) async -> Bool {
            await pollUntil(timeout: timeout) { predicate() }
        }
    }

    @MainActor
    final class SidebarViewModelMeetingListFixture {
        let manager: AppDatabaseManager
        let vault: VaultRecord

        init() throws {
            manager = try AppDatabaseManager(path: ":memory:")
            let vaultURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-sidebar-view-model-\(UUID.v7())", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
            vault = VaultRecord(
                id: .v7(),
                path: vaultURL.path,
                name: "Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
            try manager.dbQueue.write { db in
                try vault.insert(db)
            }
        }

        func makeViewModel() -> SidebarViewModel {
            let settings = AppSettings()
            settings.currentVault = vault
            let viewModel = SidebarViewModel(settings: settings)
            viewModel.setAppDatabase(manager)
            return viewModel
        }

        func stop() {
            try? FileManager.default.removeItem(at: vault.url)
        }
    }

    func insertMeeting(
        id: UUID = .v7(),
        vaultId: UUID,
        projectId: UUID? = nil,
        name: String,
        createdAt: Date = .now,
        in db: Database
    ) throws {
        try MeetingRecord(
            id: id,
            vaultId: vaultId,
            projectId: projectId,
            name: name,
            createdAt: createdAt,
            updatedAt: createdAt
        ).insert(db)
    }
#endif
