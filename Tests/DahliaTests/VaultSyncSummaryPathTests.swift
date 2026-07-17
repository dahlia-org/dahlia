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
        func projectFolderRenameUpdatesStoredSummaryPathByPrefix() throws {
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
            #expect(project.name == "Renamed")
            #expect(vaultExport?.url == "vault:///Renamed/Summary.md")
            #expect(vaultExport?.vaultRelativePath == "Renamed/Summary.md")
        }

        @Test
        func initialSyncDoesNotGuessSummaryPathFromFrontmatter() throws {
            let context = try makeContext(projectName: "Project", summaryRelativePath: "Project/Original.md")
            defer { try? FileManager.default.removeItem(at: context.vaultURL) }

            let originalURL = context.vaultURL.appending(path: "Project/Original.md")
            let archiveURL = context.vaultURL.appending(path: "Archive/Moved.md")
            try writeSummary(meetingId: context.meeting.id, to: originalURL)
            try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: originalURL, to: archiveURL)

            context.syncService.performInitialSync()

            let vaultExport = try context.repository.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .vault
            )
            #expect(vaultExport?.vaultRelativePath == "Project/Original.md")
        }

        private func makeContext(projectName: String, summaryRelativePath: String) throws -> TestContext {
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
                syncService: VaultSyncService(vaultURL: vaultURL, dbQueue: manager.dbQueue, vaultId: vault.id)
            )
        }

        private func writeSummary(meetingId: UUID, to url: URL) throws {
            try Data(
                """
                ---
                meeting_id: "\(meetingId.uuidString)"
                ---

                Summary
                """.utf8
            ).write(to: url, options: .atomic)
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
