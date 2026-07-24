import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct VaultSyncLegacyContextMigrationTests {
        @Test
        func importsLegacyContextBodyIntoProjectDescription() throws {
            let vaultURL = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let projectURL = vaultURL.appending(path: "Customer", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: vaultURL) }

            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
            let legacyContext = """
            ---
            tags:
              - customer_meeting
            ---

            <context>
            Customer rollout planning.
            </context>
            """
            try legacyContext.write(to: projectURL.appending(path: "CONTEXT.md"), atomically: true, encoding: .utf8)

            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let vault = VaultRecord(
                id: .v7(),
                path: vaultURL.path,
                name: "Test Vault",
                createdAt: .now,
                lastOpenedAt: .now
            )
            try repository.insertVault(vault)

            VaultSyncService(vaultURL: vaultURL, dbQueue: database.dbQueue, vaultId: vault.id).performInitialSync()

            let projects = try repository.fetchAllProjects(vaultId: vault.id)
            let project = try #require(projects.first(where: { $0.name == "Customer" }))
            #expect(project.description == "Customer rollout planning.")
        }

        @Test
        func doesNotImportLegacyContextThroughProjectSymlink() throws {
            let rootURL = URL.temporaryDirectory
                .appending(path: "dahlia-legacy-context-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
            let vaultURL = rootURL.appending(path: "Vault", directoryHint: .isDirectory)
            let outsideURL = rootURL.appending(path: "Outside", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
            try "Outside data".write(
                to: outsideURL.appending(path: "CONTEXT.md"),
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.createSymbolicLink(
                at: vaultURL.appending(path: "Linked", directoryHint: .isDirectory),
                withDestinationURL: outsideURL
            )

            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let vault = VaultRecord(
                id: .v7(),
                path: vaultURL.path,
                name: "Test Vault",
                createdAt: .now,
                lastOpenedAt: .now
            )
            try repository.insertVault(vault)
            let project = try repository.createProject(
                vaultId: vault.id,
                parentProjectId: nil,
                leafName: "Linked",
                description: "",
                projectType: .undefined
            )

            VaultSyncService(vaultURL: vaultURL, dbQueue: database.dbQueue, vaultId: vault.id).performInitialSync()

            let migrated = try #require(try repository.fetchProject(id: project.id))
            #expect(migrated.description.isEmpty)
            #expect(migrated.missingOnDisk)
        }
    }
#endif
