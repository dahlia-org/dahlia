import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
    struct MainSearchModelTests {
        @Test(.timeLimit(.minutes(1)))
        func presentsSixRecentMeetingsAndProjectsInNewestOrder() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertProjectsAndMeetings(count: 8)
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            #expect(await pollUntil { sidebar.isProjectCatalogLoaded })

            let model = MainSearchModel()
            model.present(using: sidebar)
            #expect(await pollUntil { !model.isLoading && !model.isProjectCatalogLoading })

            #expect(model.isRecent)
            #expect(model.meetings.count == MainSearchDesign.recentResultLimit)
            #expect(model.projects.count == MainSearchDesign.recentResultLimit)
            #expect(model.meetings.map(\.meetingName) == (2 ... 7).reversed().map { "Meeting \($0)" })
            #expect(model.projects.map(\.projectDisplayName) == (2 ... 7).reversed().map { "Project \($0)" })
            #expect(model.selectedResultID == nil)

            model.moveSelection(by: 1)
            #expect(model.selectedResultID == model.resultIDs.first)
        }

        @Test(.timeLimit(.minutes(1)))
        func defaultsToAdvancedAndKeepsAvailableModeAcrossPresentations() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertSearchContent()
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            #expect(await pollUntil { sidebar.isProjectCatalogLoaded })

            let model = MainSearchModel()
            #expect(model.searchMode == .advanced)

            model.present(using: sidebar)
            model.inputText = "Needle"
            model.queryDidChange(using: sidebar)
            #expect(await pollUntil { !model.isLoading && !model.isProjectCatalogLoading })

            model.searchMode = .simple
            model.searchModeDidChange(using: sidebar)
            #expect(await pollUntil { !model.isLoading && !model.isProjectCatalogLoading })
            #expect(model.meetings.map(\.meetingName) == ["Needle meeting"])
            #expect(model.projects.map(\.projectDisplayName) == ["Needle project"])

            model.dismiss()
            model.present(using: sidebar)
            #expect(model.searchMode == .simple)
        }

        @Test(.timeLimit(.minutes(1)))
        func switchingModeReplacesResultsFromThePreviousMode() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertSearchContent()
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            #expect(await pollUntil { sidebar.isProjectCatalogLoaded })

            let model = MainSearchModel()
            model.present(using: sidebar)
            model.inputText = "eedle"
            model.searchMode = .simple
            model.searchModeDidChange(using: sidebar)
            #expect(await pollUntil { !model.isLoading && !model.isProjectCatalogLoading })
            #expect(model.meetings.map(\.meetingName) == ["Needle meeting"])

            model.searchMode = .advanced
            model.searchModeDidChange(using: sidebar)
            #expect(model.meetings.isEmpty)
            #expect(await pollUntil { !model.isLoading && !model.isProjectCatalogLoading })
            #expect(model.meetings.isEmpty)
        }

        @Test(.timeLimit(.minutes(1)))
        func searchesMeetingsAndProjectsTogetherAndRejectsStaleQuery() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertSearchContent()
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            #expect(await pollUntil { sidebar.isProjectCatalogLoaded })

            let model = MainSearchModel()
            model.present(using: sidebar)
            model.inputText = "Older"
            model.queryDidChange(using: sidebar)
            model.inputText = "Needle"
            model.queryDidChange(using: sidebar)
            #expect(await pollUntil { !model.isLoading && !model.isProjectCatalogLoading && !model.isRecent })

            #expect(model.meetings.map(\.meetingName) == ["Needle meeting"])
            #expect(model.projects.map(\.projectDisplayName) == ["Needle project"])
        }

        @Test(.timeLimit(.minutes(1)))
        func presentsScreenshotMatchesAsTheirOwnResults() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            let expected = try await fixture.insertIndexedScreenshot(text: "Screenshot-only design token")
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            #expect(await pollUntil { sidebar.isProjectCatalogLoaded })

            let model = MainSearchModel()
            model.present(using: sidebar)
            model.inputText = "design token"
            model.queryDidChange(using: sidebar)
            #expect(model.presentedScreenshots.isEmpty)
            #expect(await pollUntil { !model.isLoading && !model.isLoadingScreenshots })

            #expect(model.meetings.isEmpty)
            #expect(model.screenshots.map(\.id) == [expected.screenshotID])
            #expect(model.presentedScreenshots.map(\.id) == [expected.screenshotID])
            #expect(model.screenshots.first?.meetingID == expected.meetingID)
            #expect(model.resultIDs == [.screenshot(expected.screenshotID)])
        }

        @Test(.timeLimit(.minutes(1)))
        func neuralSearchKeepsFTSResultsWhenEmbeddingFails() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertSearchContent()
            try await fixture.setVectorState(phase: "ready", isEnabled: true)
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            #expect(await pollUntil { sidebar.isVectorSearchReady })

            let model = MainSearchModel(embeddingService: ReviewEmbeddingProvider(throwsForQueries: true))
            model.searchMode = .neural
            model.present(using: sidebar)
            model.inputText = "Needle"
            model.queryDidChange(using: sidebar)
            #expect(await pollUntil { !model.isLoading && model.meetings.map(\.meetingName) == ["Needle meeting"] })
            #expect(model.errorMessage == nil)
        }

        @Test(.timeLimit(.minutes(1)))
        func staleNeuralCompletionDoesNotReplaceCurrentQueryEmbedding() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertSearchContent()
            try await fixture.setVectorState(phase: "ready", isEnabled: true)
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            #expect(await pollUntil { sidebar.isVectorSearchReady })
            let embedder = ReviewEmbeddingProvider(blockedQuery: "Older")

            let model = MainSearchModel(embeddingService: embedder)
            model.searchMode = .neural
            model.present(using: sidebar)
            model.inputText = "Older"
            model.queryDidChange(using: sidebar)
            #expect(await pollUntil { await embedder.didStartBlockedQuery })

            model.inputText = "Needle"
            model.queryDidChange(using: sidebar)
            #expect(await pollUntil { model.activeQueryEmbedding?.first == 2 })
            await embedder.releaseBlockedQuery()
            #expect(await pollUntil { await embedder.didFinishBlockedQuery })
            #expect(model.activeQueryEmbedding?.first == 2)
        }

        @Test(.timeLimit(.minutes(1)))
        func reopeningSearchDowngradesDisabledNeuralMode() throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            let model = MainSearchModel()
            model.searchMode = .neural

            model.present(using: sidebar)

            #expect(model.searchMode == .advanced)
        }

        @Test(.timeLimit(.minutes(1)))
        func missingModelGuidanceSurvivesModeChangeCallback() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertSearchContent()
            try await fixture.setVectorState(phase: "pending", isEnabled: true)
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            #expect(await pollUntil { sidebar.isVectorSearchEnabled })
            let model = MainSearchModel(embeddingService: ReviewEmbeddingProvider(isAvailable: false))
            model.searchMode = .neural
            model.present(using: sidebar)
            model.inputText = "Needle"
            model.queryDidChange(using: sidebar)

            #expect(await pollUntil { model.guidanceMessage == L10n.neuralModelRequired })
            model.searchModeDidChange(using: sidebar)
            #expect(await pollUntil { !model.isLoading && model.guidanceMessage == L10n.neuralModelRequired })
            #expect(model.searchMode == .neural)
            #expect(model.meetings.map(\.meetingName) == ["Needle meeting"])
            #expect(model.errorMessage == nil)
        }

        @Test(.timeLimit(.minutes(1)))
        func boundsProjectSearchResults() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertMatchingProjects(count: MainSearchDesign.projectResultLimit + 1)
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            #expect(await pollUntil { sidebar.isProjectCatalogLoaded })

            let model = MainSearchModel()
            model.present(using: sidebar)
            model.inputText = "Planning"
            model.queryDidChange(using: sidebar)
            #expect(await pollUntil { !model.isLoading && !model.isProjectCatalogLoading })

            #expect(model.projects.count == MainSearchDesign.projectResultLimit)
        }

        @Test(.timeLimit(.minutes(1)))
        func resolvesProjectQualifierIntoTokenAndFiltersMeetings() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertSearchContent()
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            #expect(await pollUntil {
                sidebar.areSearchProjectsLoaded && sidebar.isProjectCatalogLoaded
            })

            let model = MainSearchModel()
            model.present(using: sidebar)
            model.inputText = #"project:"Needle project""#
            #expect(model.submit(using: sidebar))
            #expect(await pollUntil { !model.isLoading && !model.isProjectCatalogLoading })

            #expect(model.tokens.count == 1)
            #expect(model.meetings.map(\.meetingName) == ["Needle meeting"])
            #expect(model.projects.isEmpty)
        }

        @Test(.timeLimit(.minutes(1)))
        func pagesMeetingSearchInFiftyItemBatches() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertMatchingMeetings(count: 51)
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }

            let model = MainSearchModel()
            model.present(using: sidebar)
            model.inputText = "Planning"
            model.queryDidChange(using: sidebar)
            #expect(await pollUntil { !model.isLoading && !model.isRecent })
            #expect(model.meetings.count == MainSearchDesign.meetingPageSize)
            #expect(model.hasMoreMeetings)

            model.loadMore(using: sidebar)
            #expect(await pollUntil { !model.isLoading && model.meetings.count == 51 })
            #expect(!model.hasMoreMeetings)
        }

        @Test(.timeLimit(.minutes(1)))
        func rankingChangeRestartsMeetingPagination() async throws {
            let originalPolicy = AppSettings.shared.meetingSearchRankingPolicy
            defer { AppSettings.shared.meetingSearchRankingPolicy = originalPolicy }
            AppSettings.shared.meetingSearchRankingPolicy = .standard
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertMatchingMeetings(count: MainSearchDesign.meetingPageSize + 1)
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }

            let model = MainSearchModel()
            model.present(using: sidebar)
            model.inputText = "Planning"
            model.queryDidChange(using: sidebar)
            #expect(await pollUntil { !model.isLoading && model.meetings.count == MainSearchDesign.meetingPageSize })

            AppSettings.shared.meetingSearchRankingPolicy = try #require(MeetingSearchRankingPreset.content.policy)
            model.loadMore(using: sidebar)

            #expect(await pollUntil { !model.isLoading })
            #expect(model.meetings.count == MainSearchDesign.meetingPageSize)
            #expect(model.hasMoreMeetings)
        }

        @Test(.timeLimit(.minutes(1)))
        func reportsLoadMoreFailureWithoutDiscardingTheFirstPage() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertMatchingMeetings(count: 51)
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            let model = MainSearchModel()
            model.present(using: sidebar)
            model.inputText = "Planning"
            model.queryDidChange(using: sidebar)
            #expect(await pollUntil { !model.isLoading && model.meetings.count == MainSearchDesign.meetingPageSize })
            try await fixture.manager.dbQueue.write { db in
                try db.execute(sql: "UPDATE search_index_state SET phase = 'failed' WHERE indexKind = 'fts'")
            }

            model.loadMore(using: sidebar)

            #expect(await pollUntil { !model.isLoading && model.errorMessage != nil })
            #expect(model.meetings.count == MainSearchDesign.meetingPageSize)
        }

        @Test(.timeLimit(.minutes(1)))
        func presentsEmptyStateAndReportsMissingVault() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }

            let model = MainSearchModel()
            model.present(using: sidebar)
            #expect(await pollUntil { !model.isLoading })
            #expect(!model.hasResults)
            #expect(model.errorMessage == nil)

            sidebar.setAppDatabase(nil)
            model.resetForVaultChange(using: sidebar)

            #expect(model.errorMessage == L10n.searchRequiresVault)
            #expect(!model.hasResults)
        }

        @Test(.timeLimit(.minutes(1)))
        func vaultChangeAndDismissResetAllSearchState() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertSearchContent()
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            #expect(await pollUntil { sidebar.areSearchProjectsLoaded })

            let model = MainSearchModel()
            model.present(using: sidebar)
            model.inputText = #"project:"Needle project""#
            #expect(model.submit(using: sidebar))
            #expect(await pollUntil { !model.isLoading })
            #expect(!model.tokens.isEmpty)

            sidebar.setAppDatabase(nil)
            model.resetForVaultChange(using: sidebar)
            #expect(model.inputText.isEmpty)
            #expect(model.tokens.isEmpty)
            #expect(!model.hasResults)

            model.dismiss()
            #expect(!model.isPresented)
            #expect(model.errorMessage == nil)
        }

        @Test(.timeLimit(.minutes(1)))
        func submittingPlainTextPreservesKeyboardSelection() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertMatchingMeetings(count: 2)
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }

            let model = MainSearchModel()
            model.present(using: sidebar)
            model.inputText = "Planning"
            model.queryDidChange(using: sidebar)
            #expect(await pollUntil { !model.isLoading && model.meetings.count == 2 })
            model.moveSelection(by: 1)
            let selection = model.selectedResultID

            #expect(!model.submit(using: sidebar))
            #expect(model.selectedResultID == selection)
            #expect(!model.isLoading)
        }

        @Test(.timeLimit(.minutes(1)))
        func clearsSelectionWhileReplacementSearchIsPending() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertMatchingMeetings(count: 2)
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }

            let model = MainSearchModel()
            model.present(using: sidebar)
            model.inputText = "Planning"
            model.queryDidChange(using: sidebar)
            #expect(await pollUntil { !model.isLoading && model.meetings.count == 2 })
            model.moveSelection(by: 1)
            #expect(model.selectedResultID != nil)

            model.inputText = "Missing"
            model.queryDidChange(using: sidebar)

            #expect(model.meetings.isEmpty)
            #expect(model.projects.isEmpty)
            #expect(model.selectedResultID == nil)
            model.dismiss()
        }

        @Test(.timeLimit(.minutes(1)))
        func preservesProjectSelectionWhenMeetingSearchFinishes() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertMatchingProjects(count: 3)
            try await fixture.insertMatchingMeetings(count: MainSearchDesign.meetingPageSize + 1)
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            #expect(await pollUntil { sidebar.isProjectCatalogLoaded })

            let model = MainSearchModel()
            model.present(using: sidebar)
            model.inputText = "Planning"
            model.queryDidChange(using: sidebar)
            #expect(await pollUntil {
                !model.isLoading && !model.isProjectCatalogLoading && model.projects.count == 3
            })
            #expect(model.hasMoreMeetings)

            model.moveSelection(by: -1)
            let selection = model.selectedResultID
            #expect(selection == model.projects.last.map { .project($0.id) })

            model.loadMore(using: sidebar)
            #expect(await pollUntil {
                !model.isLoading && model.meetings.count == MainSearchDesign.meetingPageSize + 1
            })
            #expect(model.selectedResultID == selection)
        }

        @Test(.timeLimit(.minutes(1)))
        func clearsProjectSelectionWhileCatalogResultsRebuild() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertMatchingProjects(count: 2)
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            #expect(await pollUntil { sidebar.isProjectCatalogLoaded })

            let model = MainSearchModel()
            model.present(using: sidebar)
            model.inputText = "Planning"
            model.queryDidChange(using: sidebar)
            #expect(await pollUntil { !model.isLoading && !model.isProjectCatalogLoading })
            model.moveSelection(by: 1)
            #expect(model.selectedResultID != nil)

            model.catalogDidChange(using: sidebar)

            #expect(model.projects.isEmpty)
            #expect(model.selectedResultID == nil)
            model.dismiss()
        }

        @Test(.timeLimit(.minutes(1)))
        func updatesProjectResultsWhenCatalogFinishesLoading() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertSearchContent()
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }

            let model = MainSearchModel()
            model.present(using: sidebar)
            #expect(model.isProjectCatalogLoading)
            #expect(model.projects.isEmpty)

            #expect(await pollUntil { sidebar.isProjectCatalogLoaded && !sidebar.allProjectItems.isEmpty })
            model.catalogDidChange(using: sidebar)
            #expect(await pollUntil { !model.isProjectCatalogLoading })

            #expect(!model.isProjectCatalogLoading)
            #expect(model.projects.map(\.projectDisplayName) == ["Needle project"])
        }

        @Test(.timeLimit(.minutes(1)))
        func resolvesPendingProjectQualifierAfterCatalogLoads() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertSearchContent()
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }

            let model = MainSearchModel()
            model.present(using: sidebar)
            model.inputText = #"project:"Needle project""#

            #expect(model.submit(using: sidebar))
            #expect(model.tokens.isEmpty)

            #expect(await pollUntil { sidebar.areSearchProjectsLoaded && !sidebar.flatProjects.isEmpty })
            model.catalogDidChange(using: sidebar)

            #expect(model.inputText.isEmpty)
            #expect(model.tokens.count == 1)
        }

        @Test(.timeLimit(.minutes(1)))
        func rebuildsMeetingSearchWhenClosedQualifierCatalogLoadsWithoutSubmit() async throws {
            let fixture = try MainSearchModelFixture()
            defer { fixture.stop() }
            try await fixture.insertSearchContent()
            let sidebar = fixture.makeSidebarViewModel()
            defer { sidebar.setAppDatabase(nil) }
            #expect(!sidebar.areSearchProjectsLoaded)

            let model = MainSearchModel()
            model.present(using: sidebar)
            model.inputText = #"project:"Needle project""#
            model.queryDidChange(using: sidebar)

            #expect(await pollUntil { sidebar.areSearchProjectsLoaded && !sidebar.flatProjects.isEmpty })
            model.catalogDidChange(using: sidebar)
            #expect(await pollUntil { !model.isLoading && !model.isProjectCatalogLoading })

            #expect(model.meetings.map(\.meetingName) == ["Needle meeting"])
            #expect(model.tokens.isEmpty)
        }
    }

    @MainActor
    private final class MainSearchModelFixture {
        let manager: AppDatabaseManager
        let vault: VaultRecord

        init() throws {
            manager = try AppDatabaseManager(path: ":memory:")
            let vaultURL = URL.temporaryDirectory
                .appending(path: "dahlia-main-search-\(UUID.v7())", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
            vault = VaultRecord(
                id: .v7(),
                path: vaultURL.path,
                name: "Search Test",
                createdAt: .now,
                lastOpenedAt: .now
            )
            try manager.dbQueue.write { db in try vault.insert(db) }
        }

        func makeSidebarViewModel() -> SidebarViewModel {
            let settings = AppSettings()
            settings.currentVault = vault
            let sidebar = SidebarViewModel(settings: settings)
            sidebar.setAppDatabase(manager)
            return sidebar
        }

        func insertProjectsAndMeetings(count: Int) async throws {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let vaultID = vault.id
            try await manager.dbQueue.write { db in
                for index in 0 ..< count {
                    try ProjectRecord(
                        id: .v7(),
                        vaultId: vaultID,
                        parentProjectId: nil,
                        name: "Project \(index)",
                        createdAt: start.addingTimeInterval(TimeInterval(index)),
                        projectType: .undefined
                    ).insert(db)
                    try Self.insertMeeting(
                        vaultID: vaultID,
                        name: "Meeting \(index)",
                        createdAt: start.addingTimeInterval(TimeInterval(index)),
                        in: db
                    )
                }
            }
            await manager.searchIndexer.drain()
        }

        func insertSearchContent() async throws {
            let projectID = UUID.v7()
            let vaultID = vault.id
            try await manager.dbQueue.write { db in
                try ProjectRecord(
                    id: projectID,
                    vaultId: vaultID,
                    parentProjectId: nil,
                    name: "Needle project",
                    createdAt: .now,
                    projectType: .undefined
                ).insert(db)
                try Self.insertMeeting(vaultID: vaultID, name: "Needle meeting", projectID: projectID, in: db)
                try Self.insertMeeting(vaultID: vaultID, name: "Older meeting", in: db)
            }
            await manager.searchIndexer.drain()
        }

        func insertIndexedScreenshot(text: String) async throws -> (screenshotID: UUID, meetingID: UUID) {
            let meetingID = UUID.v7()
            let screenshotID = UUID.v7()
            let vaultID = vault.id
            try await manager.dbQueue.write { db in
                try MeetingRecord(
                    id: meetingID,
                    vaultId: vaultID,
                    projectId: nil,
                    name: "Visual meeting",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try MeetingScreenshotRecord(
                    id: screenshotID,
                    meetingId: meetingID,
                    sessionId: nil,
                    capturedAt: .now,
                    imageData: Data([1]),
                    mimeType: "image/png",
                    ocrText: text,
                    caption: "Visual description"
                ).insert(db)
                try upsertDocument(
                    SearchDocumentProjection(
                        kind: "screenshot",
                        sourceID: screenshotID,
                        vaultID: vaultID,
                        meetingID: meetingID,
                        projectID: nil,
                        fields: SearchDocumentFields(
                            title: "",
                            description: "",
                            calendar: "",
                            tags: "",
                            projectPath: "",
                            ocr: text,
                            caption: "Visual description"
                        )
                    ),
                    generation: 1,
                    in: db
                )
                try db.execute(sql: "DELETE FROM search_index_jobs")
                try db.execute(sql: "UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'fts'")
            }
            return (screenshotID, meetingID)
        }

        func setVectorState(phase: String, isEnabled: Bool) async throws {
            try await manager.dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE search_index_state SET phase = ?, isEnabled = ?
                    WHERE indexKind = 'vector'
                    """,
                    arguments: [phase, isEnabled]
                )
            }
        }

        func insertMatchingMeetings(count: Int) async throws {
            let vaultID = vault.id
            try await manager.dbQueue.write { db in
                for index in 0 ..< count {
                    try Self.insertMeeting(vaultID: vaultID, name: "Planning \(index)", in: db)
                }
            }
            await manager.searchIndexer.drain()
        }

        func insertMatchingProjects(count: Int) async throws {
            let vaultID = vault.id
            try await manager.dbQueue.write { db in
                for index in 0 ..< count {
                    try ProjectRecord(
                        id: .v7(),
                        vaultId: vaultID,
                        parentProjectId: nil,
                        name: "Planning \(index)",
                        createdAt: .now,
                        projectType: .undefined
                    ).insert(db)
                }
            }
            await manager.searchIndexer.drain()
        }

        func stop() {
            try? FileManager.default.removeItem(at: vault.url)
        }

        private nonisolated static func insertMeeting(
            vaultID: UUID,
            name: String,
            projectID: UUID? = nil,
            createdAt: Date = .now,
            in db: Database
        ) throws {
            try MeetingRecord(
                id: .v7(),
                vaultId: vaultID,
                projectId: projectID,
                name: name,
                createdAt: createdAt,
                updatedAt: createdAt
            ).insert(db)
        }
    }

    private actor ReviewEmbeddingProvider: TextEmbeddingProviding {
        private let blockedQuery: String?
        private let throwsForQueries: Bool
        private let available: Bool
        private var releasesBlockedQuery = false
        private(set) var didStartBlockedQuery = false
        private(set) var didFinishBlockedQuery = false
        var isAvailable: Bool { available }

        init(blockedQuery: String? = nil, throwsForQueries: Bool = false, isAvailable: Bool = true) {
            self.blockedQuery = blockedQuery
            self.throwsForQueries = throwsForQueries
            available = isAvailable
        }

        func queryEmbedding(_ query: String) async throws -> [Float] {
            if throwsForQueries { throw ReviewEmbeddingError.failed }
            if query == blockedQuery {
                didStartBlockedQuery = true
                while !releasesBlockedQuery {
                    try? await Task.sleep(for: .milliseconds(10))
                    await Task.yield()
                }
                didFinishBlockedQuery = true
            }
            let value: Float = query == "Needle" ? 2 : 1
            return [value] + Array(repeating: 0, count: EmbeddingGemmaDescriptor.dimensions - 1)
        }

        func documentEmbeddings(_: [DocumentEmbeddingInput]) async throws -> [[Float]] { [] }

        func releaseBlockedQuery() {
            releasesBlockedQuery = true
        }
    }

    private enum ReviewEmbeddingError: Error {
        case failed
    }
#endif
