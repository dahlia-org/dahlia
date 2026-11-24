#if canImport(Testing)
    import DahliaMeetingAccess
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct WorkspaceManagementModelTests {
        @Test
        func outputLanguageUpdatesOnlyTheTargetAndKeepsLatestSettings() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let target = makeWorkspace(name: "Target", lastOpenedAt: .distantPast)
            let original = target
            let other = makeWorkspace(name: "Open workspace", lastOpenedAt: .now)
            try await database.dbQueue.write { db in
                try original.insert(db)
                try other.insert(db)
            }
            await model.loadWorkspaces()
            let untouched = try #require(try await database.dbQueue.read { try WorkspaceRecord.fetchOne($0, key: other.id) })
            // The row passed from the UI may predate another edit or a sync pull.
            var latest = target
            latest.name = "Latest name"
            latest.generationSettings.local.model = "latest-model"
            let saved = latest
            try await database.dbQueue.write { try saved.update($0) }

            let updated = await model.setOutputLanguage(for: original, to: .en)
            #expect(updated != nil)
            let persisted = try #require(try await database.dbQueue.read { try WorkspaceRecord.fetchOne($0, key: original.id) })
            #expect(persisted.generationSettings.outputLanguage == .en)
            #expect(persisted.name == "Latest name")
            #expect(persisted.generationSettings.local.model == "latest-model")
            #expect(persisted.lastOpenedAt == .distantPast)
            #expect(try await database.dbQueue.read { try WorkspaceRecord.fetchOne($0, key: other.id) } == untouched)
            #expect(!model.isShowingError)
            #expect(!model.isUpdatingOutputLanguage)
            #expect(model.workspaces.first { $0.id == original.id }?.generationSettings.outputLanguage == .en)
        }

        @Test
        func aDatabricksConnectionOwnsNoWorkspaceAndTheAccountKeepsItsOwn() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let source = try #require(await model.createWorkspace(named: "Keep local"))
            let account = DahliaAccountConnectionRecord(
                DatabricksConnection(id: .v7(), host: "https://new.example.com"), createdAt: .now
            )
            try await database.dbQueue.write { try account.insert($0) }
            let suite = "AccountWorkspaceTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = WorkspaceAISettingsModel(
                setupDefaults: defaults, activateRuntime: { _ in },
                databricksService: DatabricksOAuthService(storage: DatabricksTestStorage().storage)
            )
            settings.configure(dbQueue: database.dbQueue)

            // A Databricks sign-in adds a provider account; the account opens the workspace it already has.
            #expect(await settings.accountWorkspace()?.id == source.id)
            let saved = try await MeetingRepository(dbQueue: database.dbQueue).fetchAllWorkspacesAsync()
            #expect(saved.map(\.id) == [source.id])
            #expect(try await database.dbQueue.read { try UUID.fetchOne($0, sql: "SELECT databricksConnectionId FROM workspaces WHERE id = ?", arguments: [source.id]) } == nil)
        }

        @Test
        func theAccountGetsADefaultWorkspaceOnFirstUse() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let suite = "AccountWorkspaceTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = WorkspaceAISettingsModel(
                setupDefaults: defaults, activateRuntime: { _ in },
                databricksService: DatabricksOAuthService(storage: DatabricksTestStorage().storage)
            )
            settings.configure(dbQueue: database.dbQueue)

            let created = try #require(await settings.accountWorkspace())
            #expect(created.name == "Default")
            #expect(await settings.accountWorkspace()?.id == created.id)
        }

        @Test
        func aFolderOfAnotherAccountIsNotReusedForANewWorkspace() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-workspace-folder-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: folder) }
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let account = DahliaAccountConnectionRecord(
                DatabricksConnection(id: .v7(), host: "https://dbc-1.cloud.databricks.com"), createdAt: .now
            )
            try await database.dbQueue.write { try account.insert($0) }

            let local = try #require(await model.createWorkspace(at: folder))

            #expect(await model.createWorkspace(at: folder)?.id == local.id)
            #expect(try await database.dbQueue.read { try UUID.fetchOne($0, sql: "SELECT databricksConnectionId FROM workspaces WHERE id = ?", arguments: [local.id]) } == nil)
        }

        @Test
        func initialLocalWorkspaceIsCreatedOnceAcrossConcurrentCallsAndRelaunch() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            async let first = model.resolveInitialWorkspace()
            async let second = model.resolveInitialWorkspace()
            let (firstResult, secondResult) = await (first, second)
            let workspace = try #require(firstResult)
            #expect(secondResult?.id == workspace.id)
            #expect(workspace.name == "Default")
            #expect(workspace.path == nil)
            let relaunched = WorkspaceManagementModel()
            await relaunched.configure(appDatabase: database)
            #expect(await relaunched.resolveInitialWorkspace()?.id == workspace.id)
            #expect(relaunched.workspaces.count == 1)
        }

        @Test
        func initialLocalSetupPreservesExistingWorkspaceName() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let existing = try #require(await model.createWorkspace(named: "My Notes"))
            #expect(await model.resolveInitialWorkspace()?.id == existing.id)
            #expect(model.workspaces.map(\.name) == ["My Notes"])
        }

        @Test
        func defaultWorkspaceUsesTheDahliaFolderInDocuments() {
            #expect(WorkspaceManagementModel.defaultWorkspaceURL == URL.documentsDirectory
                .appending(path: "Dahlia", directoryHint: .isDirectory))
        }

        @Test
        func setupCreatesAndRegistersTheSelectedWorkspace() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let rootURL = temporaryDirectoryURL()
            let selectedURL = rootURL.appending(path: "Selected", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }

            let workspace = try #require(await model.createWorkspace(at: selectedURL))

            #expect(workspace.url == selectedURL)
            #expect(workspace.name == "Selected")
            #expect(workspace.lastOpenedAt == .distantPast)
            #expect(FileManager.default.fileExists(atPath: selectedURL.path))
            #expect(try MeetingRepository(dbQueue: database.dbQueue).fetchAllWorkspaces().map(\.id) == [workspace.id])
        }

        @Test
        func createsWorkspaceWithoutALocalExportFolder() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)

            let workspace = try #require(await model.createWorkspace(named: "  Cloud only  "))
            let stored = try #require(MeetingRepository(dbQueue: database.dbQueue).fetchAllWorkspaces().first)

            #expect(workspace.name == "Cloud only")
            #expect(workspace.path == nil)
            #expect(stored.id == workspace.id)
            #expect(stored.name == workspace.name)
            #expect(stored.path == nil)
        }

        @Test
        func changesAndRemovesLocalExportFolderWithoutQueuingServerOperations() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let workspace = try #require(await model.createWorkspace(named: "Workspace"))
            let folder = temporaryDirectoryURL()
            defer { try? FileManager.default.removeItem(at: folder) }

            let withFolder = try #require(await model.setExportFolder(for: workspace, to: folder))
            #expect(withFolder.url == folder.standardizedFileURL)
            #expect(FileManager.default.fileExists(atPath: folder.path))
            let meeting = MeetingRecord(
                id: .v7(), workspaceId: workspace.id, projectId: nil, name: "Meeting",
                createdAt: .now, updatedAt: .now
            )
            try await database.dbQueue.write { db in
                try meeting.insert(db)
                try SummaryContent(
                    meetingId: meeting.id,
                    title: "Summary",
                    document: "{}",
                    createdAt: .now
                ).insert(db)
                try SummaryExportRecord(
                    meetingId: meeting.id,
                    type: .workspace,
                    url: #require(SummaryExportRecord.workspaceURL(relativePath: "summary.md")),
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            _ = try #require(await model.setExportFolder(for: withFolder, to: folder))
            #expect(try await database.dbQueue.read { db in
                try SummaryExportRecord.fetchOne(meetingId: meeting.id, type: .workspace, in: db)
            } != nil)
            let withoutFolder = try #require(await model.setExportFolder(for: withFolder, to: nil))
            #expect(withoutFolder.path == nil)
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions")
            } == 0)
        }

        @Test
        func newWorkspaceKeepsLegacyProviderDefaults() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let rootURL = temporaryDirectoryURL()
            let selectedURL = rootURL.appending(path: "Selected", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            _ = try #require(await model.createWorkspace(at: selectedURL))
            let storedWorkspace = try #require(MeetingRepository(dbQueue: database.dbQueue).fetchAllWorkspaces().first)

            #expect(storedWorkspace.localProvider == .chatGPTSubscription)
            #expect(storedWorkspace.databricksProfile.isEmpty)
        }

        @Test
        func setupUsesDahliaAsTheDefaultWorkspaceName() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let rootURL = temporaryDirectoryURL()
            let selectedURL = rootURL.appending(path: "Dahlia", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }

            let workspace = try #require(await model.createWorkspace(at: selectedURL))

            #expect(workspace.name == "Dahlia")
        }

        @Test
        func setupMarksWorkspaceOpenedOnlyAfterTheExplicitPersistenceStep() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let rootURL = temporaryDirectoryURL()
            let selectedURL = rootURL.appending(path: "Dahlia", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let workspace = try #require(await model.createWorkspace(at: selectedURL))

            #expect(try repository.fetchLastOpenedWorkspace() == nil)
            #expect(await model.markWorkspaceOpened(workspace))
            #expect(try repository.fetchLastOpenedWorkspace()?.id == workspace.id)
            #expect(model.workspaces.first(where: { $0.id == workspace.id })?.lastOpenedAt != .distantPast)
        }

        @Test
        func setupPreservesFilesInAnExistingSelectedFolder() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let selectedURL = temporaryDirectoryURL()
            let existingFileURL = selectedURL.appending(path: "keep.txt")
            defer { try? FileManager.default.removeItem(at: selectedURL) }
            try FileManager.default.createDirectory(at: selectedURL, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: existingFileURL)

            _ = try #require(await model.createWorkspace(at: selectedURL))

            #expect(try String(contentsOf: existingFileURL, encoding: .utf8) == "keep")
        }

        @Test
        func preservesAnExistingLastOpenedWorkspaceAtStartup() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let existingWorkspace = makeWorkspace(name: "Existing", lastOpenedAt: .now)
            try repository.insertWorkspace(existingWorkspace)
            let model = WorkspaceManagementModel()
            let defaultWorkspaceURL = temporaryDirectoryURL().appending(path: "Dahlia", directoryHint: .isDirectory)

            let startupWorkspace = await model.resolveExistingStartupWorkspace(appDatabase: database)

            #expect(startupWorkspace?.id == existingWorkspace.id)
            #expect(try repository.fetchAllWorkspaces().map(\.id) == [existingWorkspace.id])
            #expect(!FileManager.default.fileExists(atPath: defaultWorkspaceURL.path))
        }

        @Test
        func doesNotCreateDefaultWorkspaceWhenExistingWorkspaceHasNeverBeenOpened() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let existingWorkspace = makeWorkspace(name: "Unopened", lastOpenedAt: .distantPast)
            try repository.insertWorkspace(existingWorkspace)
            let model = WorkspaceManagementModel()
            let defaultWorkspaceURL = temporaryDirectoryURL().appending(path: "Dahlia", directoryHint: .isDirectory)

            let startupWorkspace = await model.resolveExistingStartupWorkspace(appDatabase: database)

            #expect(startupWorkspace == nil)
            #expect(try repository.fetchAllWorkspaces() == [existingWorkspace])
            #expect(!FileManager.default.fileExists(atPath: defaultWorkspaceURL.path))
        }

        @Test
        func presentsAnErrorWithoutRegisteringWorkspaceWhenDefaultDirectoryCannotBeCreated() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            let rootURL = temporaryDirectoryURL()
            let blockingFileURL = rootURL.appending(path: "file")
            let defaultWorkspaceURL = blockingFileURL.appending(path: "Dahlia", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try Data().write(to: blockingFileURL)

            await model.configure(appDatabase: database)
            let startupWorkspace = await model.createWorkspace(at: defaultWorkspaceURL)

            #expect(startupWorkspace == nil)
            #expect(model.isShowingError)
            #expect(model.errorMessage == L10n.workspaceAddFailed)
            #expect(try MeetingRepository(dbQueue: database.dbQueue).fetchAllWorkspaces().isEmpty)
        }

        @Test
        func configureLoadsWorkspacesByLastOpenedDate() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let older = makeWorkspace(name: "Older", lastOpenedAt: Date(timeIntervalSince1970: 1))
            let newer = makeWorkspace(name: "Newer", lastOpenedAt: Date(timeIntervalSince1970: 2))
            try repository.insertWorkspace(older)
            try repository.insertWorkspace(newer)

            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)

            #expect(model.workspaces.map(\.id) == [newer.id, older.id])
        }

        @Test
        func registeringTheSameFolderReturnsTheExistingWorkspace() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let url = URL(filePath: "/tmp/Dahlia-WorkspaceManagementModelTests-Duplicate", directoryHint: .isDirectory)

            let first = try #require(await model.registerWorkspace(at: url))
            let second = try #require(await model.registerWorkspace(
                at: url.appending(path: "..").appending(path: url.lastPathComponent)
            ))

            #expect(second.id == first.id)
            #expect(model.workspaces.count == 1)
        }

        @Test
        func registeringWorkspaceFromManagementDoesNotMarkItAsOpened() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let currentWorkspace = makeWorkspace(name: "Current", lastOpenedAt: Date(timeIntervalSince1970: 1))
            try repository.insertWorkspace(currentWorkspace)
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)

            let registeredWorkspace = try #require(await model.registerWorkspace(
                at: URL(
                    filePath: "/tmp/Dahlia-WorkspaceManagementModelTests-Unopened",
                    directoryHint: .isDirectory
                ),
                markAsOpened: false
            ))

            #expect(registeredWorkspace.lastOpenedAt == .distantPast)
            #expect(try repository.fetchLastOpenedWorkspace()?.id == currentWorkspace.id)
        }

        @Test
        func registeringFirstWorkspaceFromManagementDoesNotMakeItLastOpened() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)

            _ = try #require(await model.registerWorkspace(
                at: URL(
                    filePath: "/tmp/Dahlia-WorkspaceManagementModelTests-First-Unopened",
                    directoryHint: .isDirectory
                ),
                markAsOpened: false
            ))

            #expect(try repository.fetchLastOpenedWorkspace() == nil)
        }

        @Test
        func removesANoncurrentWorkspace() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let workspace = try #require(await model.registerWorkspace(at: URL(
                filePath: "/tmp/Dahlia-WorkspaceManagementModelTests-Remove",
                directoryHint: .isDirectory
            )))

            let didRemove = await model.removeWorkspace(workspace, currentWorkspaceId: nil)

            #expect(didRemove)
            #expect(model.workspaces.isEmpty)
            #expect(try MeetingRepository(dbQueue: database.dbQueue).fetchAllWorkspaces().isEmpty)
        }

        @Test
        func renamesAWorkspaceAndPersistsTheTrimmedName() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let workspace = try #require(await model.registerWorkspace(at: URL(
                filePath: "/tmp/Dahlia-WorkspaceManagementModelTests-Rename",
                directoryHint: .isDirectory
            )))

            let renamedWorkspace = try #require(await model.renameWorkspace(workspace, to: "  Customer Interviews  "))

            #expect(renamedWorkspace.name == "Customer Interviews")
            #expect(model.workspaces.first?.name == "Customer Interviews")
            #expect(try MeetingRepository(dbQueue: database.dbQueue).fetchAllWorkspaces().first?.name == "Customer Interviews")
        }

        @Test
        func doesNotRenameAWorkspaceToABlankName() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let workspace = makeWorkspace(name: "Original", lastOpenedAt: .now)
            try MeetingRepository(dbQueue: database.dbQueue).insertWorkspace(workspace)
            await model.loadWorkspaces()

            let renamedWorkspace = await model.renameWorkspace(workspace, to: "  \n  ")

            #expect(renamedWorkspace == nil)
            #expect(model.workspaces.first?.name == "Original")
            #expect(try MeetingRepository(dbQueue: database.dbQueue).fetchAllWorkspaces().first?.name == "Original")
        }

        @Test
        func doesNotRemoveTheCurrentWorkspace() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let workspace = try #require(await model.registerWorkspace(at: URL(
                filePath: "/tmp/Dahlia-WorkspaceManagementModelTests-Current",
                directoryHint: .isDirectory
            )))

            let didRemove = await model.removeWorkspace(workspace, currentWorkspaceId: workspace.id)

            #expect(!didRemove)
            #expect(model.workspaces.map(\.id) == [workspace.id])
            #expect(try MeetingRepository(dbQueue: database.dbQueue).fetchAllWorkspaces().map(\.id) == [workspace.id])
        }

        @Test
        func registrationWithoutADatabasePresentsAnError() async {
            let model = WorkspaceManagementModel()

            let workspace = await model.registerWorkspace(at: URL(filePath: "/tmp/Unavailable", directoryHint: .isDirectory))

            #expect(workspace == nil)
            #expect(model.isShowingError)
            #expect(model.errorMessage == L10n.workspaceAddFailed)
        }

        @Test
        func configuringAfterDatabaseBecomesAvailableLoadsWorkspaces() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let workspace = makeWorkspace(name: "Available", lastOpenedAt: .now)
            try repository.insertWorkspace(workspace)
            let model = WorkspaceManagementModel()

            await model.configure(appDatabase: nil)
            await model.configure(appDatabase: database)

            #expect(model.workspaces.map(\.id) == [workspace.id])
        }

        private func makeWorkspace(name: String, lastOpenedAt: Date) -> WorkspaceRecord {
            WorkspaceRecord(
                id: .v7(),
                path: "/tmp/\(name)",
                name: name,
                createdAt: lastOpenedAt,
                lastOpenedAt: lastOpenedAt
            )
        }

        private func temporaryDirectoryURL() -> URL {
            URL.temporaryDirectory
                .appending(path: "Dahlia-WorkspaceManagementModelTests-\(UUID())", directoryHint: .isDirectory)
        }
    }
#endif
