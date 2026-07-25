import CoreServices
import Foundation
import GRDB
#if canImport(Testing)
    import Testing
    @testable import Dahlia

    @MainActor
    struct VaultSyncProjectHierarchyTests {
        @Test
        func initialSyncNeverCreatesProjectsFromDirectories() throws {
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
            #expect(projects.isEmpty)
        }

        @Test
        func directoryCreationEventNeverCreatesAProject() throws {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let directory = fixture.vaultURL.appending(path: "Personal", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

            fixture.service.handleEvents(
                paths: [directory.path],
                flags: [
                    UInt32(kFSEventStreamEventFlagItemCreated)
                        | UInt32(kFSEventStreamEventFlagItemIsDir),
                ]
            )

            let projects = try fixture.database.dbQueue.read { db in
                try ProjectRecord.fetchResolvedAll(vaultId: fixture.vaultID, in: db)
            }
            #expect(projects.isEmpty)
        }

        @Test
        func directoryRenameDoesNotChangeProjectIdentityPathOrRevision() throws {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let project = try fixture.insertProject(named: "Original")
            let originalURL = fixture.vaultURL.appending(path: "Original", directoryHint: .isDirectory)
            let renamedURL = fixture.vaultURL.appending(path: "Renamed", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: originalURL, withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: originalURL, to: renamedURL)

            let renameFlag = UInt32(kFSEventStreamEventFlagItemRenamed)
                | UInt32(kFSEventStreamEventFlagItemIsDir)
            fixture.service.handleEvents(
                paths: [originalURL.path, renamedURL.path],
                flags: [renameFlag, renameFlag]
            )

            let unchanged = try fixture.database.dbQueue.read { db in
                try #require(try ProjectRecord.fetchResolved(id: project.id, in: db))
            }
            #expect(unchanged.id == project.id)
            #expect(unchanged.name == "Original")
            #expect(unchanged.revision == project.revision)
        }

        @Test
        func missingDerivedDirectoryDoesNotChangeProject() throws {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let project = try fixture.insertProject(named: "No Output Yet")

            fixture.service.performInitialSync()

            let unchanged = try fixture.database.dbQueue.read { db in
                try #require(try ProjectRecord.fetchResolved(id: project.id, in: db))
            }
            #expect(unchanged.id == project.id)
            #expect(unchanged.name == project.leafName)
            #expect(unchanged.parentProjectId == project.parentProjectId)
            #expect(unchanged.projectType == project.projectType)
            #expect(unchanged.revision == project.revision)
            #expect(!FileManager.default.fileExists(atPath: fixture.vaultURL.appending(path: project.name).path))
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

            func insertProject(named name: String) throws -> ProjectRecord {
                let project = ProjectRecord(
                    id: .v7(),
                    vaultId: vaultID,
                    parentProjectId: nil,
                    leafName: name,
                    createdAt: .now,
                    projectType: .undefined
                )
                try database.dbQueue.write { db in
                    try project.insert(db)
                }
                return project
            }
        }
    }
#endif
