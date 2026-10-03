import CoreServices
import Foundation
import GRDB
#if canImport(Testing)
    import Testing
    @testable import Dahlia

    @MainActor
    struct WorkspaceSyncProjectHierarchyTests {
        @Test
        func directoryCreationEventNeverCreatesAProject() throws {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let directory = fixture.workspaceURL.appending(path: "Personal", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

            fixture.service.handleEvents(
                paths: [directory.path],
                flags: [
                    UInt32(kFSEventStreamEventFlagItemCreated)
                        | UInt32(kFSEventStreamEventFlagItemIsDir),
                ]
            )

            let projects = try fixture.database.dbQueue.read { db in
                try ProjectRecord.fetchResolvedAll(workspaceId: fixture.workspaceID, in: db)
            }
            #expect(projects.isEmpty)
        }

        @Test
        func directoryRenameDoesNotChangeProjectIdentityPathOrRevision() throws {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let project = try fixture.insertProject(named: "Original")
            let originalURL = fixture.workspaceURL.appending(path: "Original", directoryHint: .isDirectory)
            let renamedURL = fixture.workspaceURL.appending(path: "Renamed", directoryHint: .isDirectory)
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
    }

    private extension WorkspaceSyncProjectHierarchyTests {
        final class Fixture {
            let rootURL: URL
            let workspaceURL: URL
            let workspaceID = UUID.v7()
            let database: AppDatabaseManager
            let service: WorkspaceSyncService

            init() throws {
                rootURL = URL.temporaryDirectory.appending(path: "dahlia-workspace-sync-\(UUID.v7().uuidString)")
                workspaceURL = rootURL.appending(path: "Workspace", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
                let database = try AppDatabaseManager(path: ":memory:")
                self.database = database
                service = WorkspaceSyncService(workspaceURL: workspaceURL, dbQueue: database.dbQueue, workspaceId: workspaceID)
                try database.dbQueue.write { db in
                    try WorkspaceRecord(
                        id: workspaceID,
                        path: workspaceURL.path,
                        name: "Workspace",
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
                    workspaceId: workspaceID,
                    parentProjectId: nil,
                    name: name,
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
