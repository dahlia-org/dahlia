import CoreServices
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct VaultSyncSummaryPathTests {
        @Test
        func markdownRenameUpdatesStoredSummaryPathWithoutReadingFrontmatter() throws {
            let context = try makeContext(projectName: "Project", summaryRelativePath: "Project/Original.md")
            defer { try? FileManager.default.removeItem(at: context.vaultURL) }

            let originalURL = context.vaultURL.appending(path: "Project/Original.md")
            let renamedURL = context.vaultURL.appending(path: "Project/Renamed.md")
            try Data("Summary".utf8).write(to: originalURL, options: .atomic)
            try FileManager.default.moveItem(at: originalURL, to: renamedURL)

            let renameFlag = UInt32(kFSEventStreamEventFlagItemRenamed)
                | UInt32(kFSEventStreamEventFlagItemIsFile)
            context.syncService.handleEvents(
                paths: [originalURL.path, renamedURL.path],
                flags: [renameFlag, renameFlag]
            )

            let vaultExport = try context.repository.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .vault
            )
            #expect(vaultExport?.url == "vault:///Project/Renamed.md")
            #expect(vaultExport?.vaultRelativePath == "Project/Renamed.md")
        }

        @Test
        func multipleMarkdownRenamesNeverInventPathPairings() throws {
            let context = try makeContext(projectName: "Project", summaryRelativePath: "Project/First.md")
            defer { try? FileManager.default.removeItem(at: context.vaultURL) }
            let second = try insertMeeting(
                project: context.project,
                summaryRelativePath: "Project/Second.md",
                repository: context.repository
            )
            let projectURL = context.vaultURL.appending(path: "Project", directoryHint: .isDirectory)
            let firstOld = projectURL.appending(path: "First.md")
            let secondOld = projectURL.appending(path: "Second.md")
            let firstNew = projectURL.appending(path: "First Renamed.md")
            let secondNew = projectURL.appending(path: "Second Renamed.md")
            try Data("First".utf8).write(to: firstOld)
            try Data("Second".utf8).write(to: secondOld)
            try FileManager.default.moveItem(at: firstOld, to: firstNew)
            try FileManager.default.moveItem(at: secondOld, to: secondNew)

            let renameFlag = UInt32(kFSEventStreamEventFlagItemRenamed)
                | UInt32(kFSEventStreamEventFlagItemIsFile)
            context.syncService.handleEvents(
                paths: [firstOld.path, secondOld.path, firstNew.path, secondNew.path],
                flags: Array(repeating: renameFlag, count: 4)
            )

            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: context.meeting.id) == nil)
            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: second.id) == nil)
        }

        @Test
        func laterBatchProcessesAfterRetryExhaustion() throws {
            let context = try makeContext(
                projectName: "Project",
                summaryRelativePath: "Project/Original.md",
                maximumEventRetryAttempts: 0
            )
            defer { try? FileManager.default.removeItem(at: context.vaultURL) }

            let originalURL = context.vaultURL.appending(path: "Project/Original.md")
            let renamedURL = context.vaultURL.appending(path: "Project/Renamed.md")
            try Data("Summary".utf8).write(to: originalURL, options: .atomic)
            try FileManager.default.moveItem(at: originalURL, to: renamedURL)
            try context.repository.dbQueue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER fail_summary_path_update
                BEFORE UPDATE ON summary_exports
                BEGIN
                    SELECT RAISE(ABORT, 'forced summary path failure');
                END
                """)
            }
            let renameFlag = UInt32(kFSEventStreamEventFlagItemRenamed)
                | UInt32(kFSEventStreamEventFlagItemIsFile)

            context.syncService.handleEvents(
                paths: [originalURL.path, renamedURL.path],
                flags: [renameFlag, renameFlag]
            )
            try context.repository.dbQueue.write { db in
                try db.execute(sql: "DROP TRIGGER fail_summary_path_update")
            }
            context.syncService.handleEvents(
                paths: [originalURL.path, renamedURL.path],
                flags: [renameFlag, renameFlag]
            )

            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: context.meeting.id) == "Project/Renamed.md")
        }

        @Test
        func markdownRenameThroughParentSymlinkClearsUnsafeStoredPath() throws {
            let context = try makeContext(projectName: "Project", summaryRelativePath: "Project/Original.md")
            let originalURL = context.vaultURL.appending(path: "Project/Original.md")
            let outsideDirectory = context.vaultURL.deletingLastPathComponent()
                .appending(path: "Outside-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer {
                try? FileManager.default.removeItem(at: context.vaultURL)
                try? FileManager.default.removeItem(at: outsideDirectory)
            }
            let linkURL = context.vaultURL.appending(path: "Link", directoryHint: .isDirectory)
            let unsafeURL = linkURL.appending(path: "Renamed.md")
            try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideDirectory)
            try Data("Summary".utf8).write(to: originalURL, options: .atomic)
            try FileManager.default.moveItem(
                at: originalURL,
                to: outsideDirectory.appending(path: "Renamed.md")
            )

            let renameFlag = UInt32(kFSEventStreamEventFlagItemRenamed)
                | UInt32(kFSEventStreamEventFlagItemIsFile)
            context.syncService.handleEvents(
                paths: [originalURL.path, unsafeURL.path],
                flags: [renameFlag, renameFlag]
            )

            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: context.meeting.id) == nil)
            #expect(FileManager.default.fileExists(atPath: unsafeURL.path))
        }

        @Test
        func directoryRenameUpdatesOnlyStoredSummaryPath() throws {
            let context = try makeContext(projectName: "Original", summaryRelativePath: "Original/Summary.md")
            defer { try? FileManager.default.removeItem(at: context.vaultURL) }

            let originalURL = context.vaultURL.appending(path: "Original", directoryHint: .isDirectory)
            let renamedURL = context.vaultURL.appending(path: "Renamed", directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: originalURL, to: renamedURL)

            let renameFlag = UInt32(kFSEventStreamEventFlagItemRenamed)
                | UInt32(kFSEventStreamEventFlagItemIsDir)
            context.syncService.handleEvents(
                paths: [originalURL.path, renamedURL.path],
                flags: [renameFlag, renameFlag]
            )

            let fetchedProject = try context.repository.fetchProject(id: context.project.id)
            let vaultExport = try context.repository.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .vault
            )
            let project = try #require(fetchedProject)
            #expect(project.id == context.project.id)
            #expect(project.path == "Original")
            #expect(vaultExport?.url == "vault:///Renamed/Summary.md")
            #expect(vaultExport?.vaultRelativePath == "Renamed/Summary.md")
        }

        @Test
        func multipleDirectoryRenamesNeverInventPrefixPairings() throws {
            let context = try makeContext(projectName: "First", summaryRelativePath: "First/Summary.md")
            defer { try? FileManager.default.removeItem(at: context.vaultURL) }
            let secondProjectURL = context.vaultURL.appending(path: "Second", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: secondProjectURL, withIntermediateDirectories: false)
            let secondProject = try context.repository.fetchOrCreateProject(
                name: "Second",
                vaultId: context.project.vaultId
            )
            let second = try insertMeeting(
                project: secondProject,
                summaryRelativePath: "Second/Summary.md",
                repository: context.repository
            )
            let firstOld = context.vaultURL.appending(path: "First", directoryHint: .isDirectory)
            let secondOld = secondProjectURL
            let firstNew = context.vaultURL.appending(path: "First Renamed", directoryHint: .isDirectory)
            let secondNew = context.vaultURL.appending(path: "Second Renamed", directoryHint: .isDirectory)
            try Data("First".utf8).write(to: firstOld.appending(path: "Summary.md"))
            try Data("Second".utf8).write(to: secondOld.appending(path: "Summary.md"))
            try FileManager.default.moveItem(at: firstOld, to: firstNew)
            try FileManager.default.moveItem(at: secondOld, to: secondNew)

            let renameFlag = UInt32(kFSEventStreamEventFlagItemRenamed)
                | UInt32(kFSEventStreamEventFlagItemIsDir)
            context.syncService.handleEvents(
                paths: [firstOld.path, secondOld.path, firstNew.path, secondNew.path],
                flags: Array(repeating: renameFlag, count: 4)
            )

            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: context.meeting.id) == nil)
            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: second.id) == nil)
            #expect(try context.repository.fetchProject(id: context.project.id)?.path == "First")
            #expect(try context.repository.fetchProject(id: secondProject.id)?.path == "Second")
        }

        @Test
        func directoryRemovalClearsSummaryPathWithoutChangingProject() throws {
            let context = try makeContext(projectName: "Project", summaryRelativePath: "Project/Summary.md")
            defer { try? FileManager.default.removeItem(at: context.vaultURL) }
            let projectURL = context.vaultURL.appending(path: "Project", directoryHint: .isDirectory)
            try Data("Summary".utf8).write(to: projectURL.appending(path: "Summary.md"), options: .atomic)
            try FileManager.default.removeItem(at: projectURL)

            context.syncService.handleEvents(
                paths: [projectURL.path],
                flags: [
                    UInt32(kFSEventStreamEventFlagItemRemoved)
                        | UInt32(kFSEventStreamEventFlagItemIsDir),
                ]
            )

            #expect(try context.repository.fetchSummaryVaultRelativePath(forMeetingId: context.meeting.id) == nil)
            #expect(try context.repository.fetchProject(id: context.project.id)?.name == "Project")
        }

        private func makeContext(
            projectName: String,
            summaryRelativePath: String,
            maximumEventRetryAttempts: Int = 5
        ) throws -> TestContext {
            let vaultURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: vaultURL.appending(path: projectName, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )

            let manager = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: manager.dbQueue)
            let vault = VaultRecord(
                id: .v7(),
                path: vaultURL.path,
                name: "Test Vault",
                createdAt: .now,
                lastOpenedAt: .now
            )
            try repository.insertVault(vault)
            let project = try repository.fetchOrCreateProject(name: projectName, vaultId: vault.id)
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: project.id,
                name: "Meeting",
                createdAt: .now,
                updatedAt: .now
            )
            try manager.dbQueue.write { db in
                try meeting.insert(db)
            }
            try repository.upsertSummary(
                SummaryRecord(
                    meetingId: meeting.id,
                    title: "Summary",
                    document: try SummaryDocument(title: "Summary", sections: []).databaseJSONString(),
                    createdAt: .now
                )
            )
            try repository.updateSummaryVaultRelativePath(
                forMeetingId: meeting.id,
                relativePath: summaryRelativePath
            )

            return TestContext(
                vaultURL: vaultURL,
                repository: repository,
                project: project,
                meeting: meeting,
                syncService: VaultSyncService(
                    vaultURL: vaultURL,
                    dbQueue: manager.dbQueue,
                    vaultId: vault.id,
                    maximumEventRetryAttempts: maximumEventRetryAttempts
                )
            )
        }

        private func insertMeeting(
            project: ProjectRecord,
            summaryRelativePath: String,
            repository: MeetingRepository
        ) throws -> MeetingRecord {
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: project.vaultId,
                projectId: project.id,
                name: "Meeting",
                createdAt: .now,
                updatedAt: .now
            )
            try repository.dbQueue.write { db in
                try meeting.insert(db)
            }
            try repository.upsertSummary(
                SummaryRecord(
                    meetingId: meeting.id,
                    title: "Summary",
                    document: try SummaryDocument(title: "Summary", sections: []).databaseJSONString(),
                    createdAt: .now
                )
            )
            try repository.updateSummaryVaultRelativePath(
                forMeetingId: meeting.id,
                relativePath: summaryRelativePath
            )
            return meeting
        }

        private struct TestContext {
            let vaultURL: URL
            let repository: MeetingRepository
            let project: ProjectRecord
            let meeting: MeetingRecord
            let syncService: VaultSyncService
        }
    }
#endif
