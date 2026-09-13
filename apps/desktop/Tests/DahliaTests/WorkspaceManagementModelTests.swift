#if canImport(Testing)
    import DahliaMeetingAccess
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct WorkspaceManagementModelTests {
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
            let workspace = try #require(await model.createWorkspace(at: selectedURL))
            let storedWorkspace = try #require(MeetingRepository(dbQueue: database.dbQueue).fetchAllWorkspaces().first)

            #expect(workspace.accountConnectionId == nil)
            #expect(storedWorkspace.localProvider == .chatGPTSubscription)
            #expect(storedWorkspace.databricksProfile.isEmpty)
            #expect(storedWorkspace.accountConnectionId == nil)
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
        func loadingWorkspacesDoesNotRequireNetworkDiscovery() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let model = WorkspaceManagementModel { _ in
                Issue.record("Listing local working copies must not fetch from the network")
                throw URLError(.notConnectedToInternet)
            }
            await model.configure(appDatabase: database)
            #expect(model.hasLoadedWorkspaces)
            #expect(model.workspaces.isEmpty)
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
        func preservesAnAutomaticallyAvailableMemberWorkspace() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "desktop-client", createdAt: .now
            )
            var workspace = makeWorkspace(name: "Shared", lastOpenedAt: .distantPast)
            workspace.accountConnectionId = connection.id
            if workspace.syncRole == nil { workspace.syncRole = "admin" }
            if workspace.organizationId == nil { workspace.organizationId = .v7() }
            workspace.syncConfirmedConnectionId = connection.id
            workspace.syncRole = "viewer"
            let workspaceID = workspace.id
            try await repository.insertDahliaAccountConnection(connection)
            try await repository.insertCloudWorkspaceAsync(workspace, revision: 1)
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_entity_state WHERE workspace_id = ?", arguments: [workspaceID])
            } == 1)

            let didRemove = await model.removeWorkspace(workspace, currentWorkspaceId: nil)

            #expect(!didRemove)
            #expect(try repository.fetchAllWorkspaces().map(\.id) == [workspaceID])
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_entity_state WHERE workspace_id = ?", arguments: [workspaceID])
            } == 1)
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
        func doesNotRenameAnImportedMemberWorkspace() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "desktop-client", createdAt: .now
            )
            var workspace = makeWorkspace(name: "Shared", lastOpenedAt: .now)
            workspace.accountConnectionId = connection.id
            if workspace.syncRole == nil { workspace.syncRole = "admin" }
            if workspace.organizationId == nil { workspace.organizationId = .v7() }
            workspace.syncConfirmedConnectionId = connection.id
            workspace.syncRole = "viewer"
            try await repository.insertDahliaAccountConnection(connection)
            try await repository.insertCloudWorkspaceAsync(workspace, revision: 1)
            let model = WorkspaceManagementModel()
            await model.configure(appDatabase: database)

            let renamed = await model.renameWorkspace(workspace, to: "Rejected")

            #expect(renamed == nil)
            #expect(try repository.fetchAllWorkspaces().first?.name == "Shared")
        }

        @Test
        func serverAdoptionWaitsForConfirmation() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let connection = DahliaAccountConnectionRecord(
                id: .v7(),
                origin: "https://server.example.com",
                clientID: "desktop-client",
                createdAt: .now
            )
            let workspace = makeWorkspace(name: "Local", lastOpenedAt: .now)
            try await repository.insertDahliaAccountConnection(connection)
            try repository.insertWorkspace(workspace)
            let model = WorkspaceManagementModel(cloudWorkspaceFetcher: { _ in [] }, organizationFetcher: { _ in [] })
            await model.configure(appDatabase: database)
            let account = DahliaAccountConnection(
                record: connection,
                account: DahliaCloudAccount(id: "user", name: "User", email: nil),
                isCloud: false,
                grantedScopes: ["all-apis"]
            )
            await model.requestServerAdoption(for: workspace, connection: account)
            #expect(model.pendingServerAdoption?.serverWorkspaces.isEmpty == true)
            #expect(try repository.fetchAllWorkspaces().first?.accountConnectionId == nil)
            model.cancelServerAdoption()
            #expect(model.pendingServerAdoption == nil)
            #expect(try repository.fetchAllWorkspaces().first?.accountConnectionId == nil)
        }

        @Test(arguments: ["viewer", "editor"])
        func adoptingSameIDRequiresAnAdmin(role: String) async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let workspace = makeWorkspace(name: "Local", lastOpenedAt: .now)
            try repository.insertWorkspace(workspace)
            let remote = CloudWorkspaceRecord(
                workspaceId: workspace.id,
                connectionId: .v7(),
                organizationId: .v7(),
                name: "Server",
                createdAt: .now,
                revision: 1,
                role: role
            )
            await #expect(throws: LocalWorkspaceImportError.self) {
                try await repository.adoptWorkspaceForServerSync(
                    id: workspace.id,
                    connectionID: remote.connectionId,
                    serverWorkspace: remote,
                    expectedChanges: 0
                )
            }
            #expect(try repository.fetchAllWorkspaces().first?.accountConnectionId == nil)
        }

        @Test
        func adoptionPreservesTheLocalWorkspaceWhenAccessWasRevokedBeforeConfirmation() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let connection = DahliaAccountConnectionRecord(
                id: .v7(),
                origin: "https://server.example.com",
                clientID: "desktop-client",
                createdAt: .now
            )
            let workspace = makeWorkspace(name: "Local", lastOpenedAt: .now)
            let remote = CloudWorkspaceRecord(
                workspaceId: .v7(),
                connectionId: connection.id,
                organizationId: .v7(),
                name: "Server",
                createdAt: .now,
                revision: 7,
                role: "editor"
            )
            var responses = [[remote], []]
            try await repository.insertDahliaAccountConnection(connection)
            try repository.insertWorkspace(workspace)
            let model = WorkspaceManagementModel(cloudWorkspaceFetcher: { _ in responses.removeFirst() }, organizationFetcher: { _ in [] })
            await model.configure(appDatabase: database)
            let account = DahliaAccountConnection(
                record: connection,
                account: DahliaCloudAccount(id: "user", name: "User", email: nil),
                isCloud: false,
                grantedScopes: ["all-apis"]
            )
            await model.requestServerAdoption(for: workspace, connection: account)
            let pending = try #require(model.pendingServerAdoption)
            #expect(await model.confirmServerAdoption(pending, destinationId: remote.workspaceId, organizationId: nil) == nil)
            #expect(try repository.fetchAllWorkspaces().first(where: { $0.id == workspace.id })?.accountConnectionId == nil)
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
