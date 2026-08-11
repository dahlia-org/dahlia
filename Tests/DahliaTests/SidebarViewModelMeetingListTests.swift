import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
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
        func debouncesSearchAndKeepsTranscriptTextOutOfResults() async throws {
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
            let viewModel = fixture.makeViewModel()
            defer {
                viewModel.setAppDatabase(nil)
            }
            #expect(await waitUntil { viewModel.isMeetingListLoaded })

            viewModel.updateMeetingSearchQuery("Needle")

            #expect(viewModel.isSearchingMeetings)
            #expect(!viewModel.isMeetingSearchLoaded)
            #expect(await waitUntil {
                viewModel.isMeetingSearchLoaded && viewModel.meetingSearchItems.map(\.id) == [metadataMeetingID]
            })

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

    private func insertMeeting(
        vaultId: UUID,
        name: String,
        createdAt: Date = .now,
        in db: Database
    ) throws {
        try MeetingRecord(
            id: .v7(),
            vaultId: vaultId,
            projectId: nil,
            name: name,
            createdAt: createdAt,
            updatedAt: createdAt
        ).insert(db)
    }
#endif
