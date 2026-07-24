import CoreServices
import Foundation
#if canImport(Testing)
    import Testing
    @testable import Dahlia

    struct VaultSyncProjectHierarchyTests {
        @Test
        func initialSyncCreatesEveryIntermediateProjectWithCanonicalParents() throws {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try FileManager.default.createDirectory(
                at: fixture.vaultURL.appending(path: "Acme/Platform/API", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )

            fixture.service.performInitialSync()

            let projects = try fixture.database.dbQueue.read { db in
                try ProjectRecord.fetchResolvedAll(vaultId: fixture.vaultID, in: db)
            }
            #expect(projects.map(\.name) == ["Acme", "Acme/Platform", "Acme/Platform/API"])
            let root = try #require(projects.first(where: { $0.name == "Acme" }))
            let platform = try #require(projects.first(where: { $0.name == "Acme/Platform" }))
            let api = try #require(projects.first(where: { $0.name == "Acme/Platform/API" }))
            #expect(root.parentProjectId == nil)
            #expect(platform.parentProjectId == root.id)
            #expect(api.parentProjectId == platform.id)
        }

        @Test
        func initialSyncMarksMissingProjectWithoutDeletingItsIdentity() throws {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try FileManager.default.createDirectory(
                at: fixture.vaultURL.appending(path: "Personal", directoryHint: .isDirectory),
                withIntermediateDirectories: false
            )
            fixture.service.performInitialSync()
            let project = try fixture.database.dbQueue.read { db in
                try #require(ProjectRecord.fetchResolvedAll(vaultId: fixture.vaultID, in: db).first)
            }

            try FileManager.default.removeItem(at: fixture.vaultURL.appending(path: "Personal"))
            fixture.service.performInitialSync()

            let missing = try fixture.database.dbQueue.read { db in
                try ProjectRecord.fetchResolved(id: project.id, in: db)
            }
            #expect(missing?.id == project.id)
            #expect(missing?.missingOnDisk == true)
        }

        @Test
        func initialSyncPreservesIdentityAndRevisionAcrossOfflineCaseRename() throws {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let originalURL = fixture.vaultURL.appending(path: "Acme", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: originalURL, withIntermediateDirectories: false)
            fixture.service.performInitialSync()
            let original = try fixture.database.dbQueue.read { db in
                try #require(ProjectRecord.fetchResolvedAll(vaultId: fixture.vaultID, in: db).first)
            }

            let temporaryURL = fixture.vaultURL.appending(path: "case-rename-temporary")
            let renamedURL = fixture.vaultURL.appending(path: "acme", directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: originalURL, to: temporaryURL)
            try FileManager.default.moveItem(at: temporaryURL, to: renamedURL)
            fixture.service.performInitialSync()

            let renamed = try fixture.database.dbQueue.read { db in
                try #require(try ProjectRecord.fetchResolved(id: original.id, in: db))
            }
            #expect(renamed.id == original.id)
            #expect(renamed.name == "acme")
            #expect(!renamed.missingOnDisk)
            #expect(renamed.revision > original.revision)
        }

        @Test
        func restoringMissingDirectoryInvalidatesOldRevision() throws {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let projectURL = fixture.vaultURL.appending(path: "Personal", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: false)
            fixture.service.performInitialSync()
            let id = try fixture.database.dbQueue.read { db in
                try #require(ProjectRecord.fetchResolvedAll(vaultId: fixture.vaultID, in: db).first).id
            }

            try FileManager.default.removeItem(at: projectURL)
            fixture.service.performInitialSync()
            let missingRevision = try fixture.database.dbQueue.read { db in
                try #require(try ProjectRecord.fetchResolved(id: id, in: db)).revision
            }
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: false)
            fixture.service.performInitialSync()

            let restored = try fixture.database.dbQueue.read { db in
                try #require(try ProjectRecord.fetchResolved(id: id, in: db))
            }
            #expect(!restored.missingOnDisk)
            #expect(restored.revision > missingRevision)
        }

        @Test
        func directoryScanDoesNotTraverseSymlinks() throws {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let outsideURL = fixture.rootURL.appending(path: "Outside/Child", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: fixture.vaultURL.appending(path: "Linked", directoryHint: .isDirectory),
                withDestinationURL: outsideURL.deletingLastPathComponent()
            )

            fixture.service.performInitialSync()

            let projects = try fixture.database.dbQueue.read { db in
                try ProjectRecord.fetchResolvedAll(vaultId: fixture.vaultID, in: db)
            }
            #expect(projects.isEmpty)
        }

        @Test
        func liveDirectoryEventDoesNotProjectizeSymlink() throws {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let outsideURL = fixture.rootURL.appending(path: "Outside", directoryHint: .isDirectory)
            let linkedURL = fixture.vaultURL.appending(path: "Linked", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: outsideURL)

            fixture.service.handleEvents(
                paths: [linkedURL.path],
                flags: [
                    UInt32(kFSEventStreamEventFlagItemCreated)
                        | UInt32(kFSEventStreamEventFlagItemIsDir)
                        | UInt32(kFSEventStreamEventFlagItemIsSymlink),
                ]
            )

            let projects = try fixture.database.dbQueue.read { db in
                try ProjectRecord.fetchResolvedAll(vaultId: fixture.vaultID, in: db)
            }
            #expect(projects.isEmpty)
        }
    }

    private extension VaultSyncProjectHierarchyTests {
        final class Fixture {
            let rootURL: URL
            let vaultURL: URL
            let vaultID = UUID.v7()
            let database: AppDatabaseManager
            let service: VaultSyncService

            init() throws {
                rootURL = URL.temporaryDirectory.appending(path: "dahlia-vault-sync-\(UUID.v7().uuidString)")
                vaultURL = rootURL.appending(path: "Vault", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
                let database = try AppDatabaseManager(path: ":memory:")
                self.database = database
                service = VaultSyncService(vaultURL: vaultURL, dbQueue: database.dbQueue, vaultId: vaultID)
                try database.dbQueue.write { db in
                    try VaultRecord(
                        id: vaultID,
                        path: vaultURL.path,
                        name: "Vault",
                        createdAt: .now,
                        lastOpenedAt: .now
                    ).insert(db)
                }
            }

            func cleanup() {
                try? FileManager.default.removeItem(at: rootURL)
            }
        }
    }
#endif
