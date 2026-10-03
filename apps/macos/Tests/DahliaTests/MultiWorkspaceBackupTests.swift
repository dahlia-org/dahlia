import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MultiWorkspaceBackupTests {
        @Test
        func mixedRestorePreservesSkippedWorkspacesAndSharedTags() async throws {
            let fixture = try BatchAudioTestFixture(name: "MultiWorkspace", endedAt: .now, batchCompletedAt: .now)
            defer { fixture.removeFiles() }
            let second = try addWorkspace(to: fixture, name: "Same")
            let skipped = try addWorkspace(to: fixture, name: "Same")
            let other = try addWorkspace(to: fixture, name: "Excluded")
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "INSERT INTO tags(name, colorHex, createdAt) VALUES ('Shared', '#000000', ?)", arguments: [fixture.now])
                let tagId = db.lastInsertedRowID
                for meetingId in [fixture.meeting.id, second.meeting.id] {
                    try db.execute(sql: "INSERT INTO meeting_tags(meetingId, tagId) VALUES (?, ?)", arguments: [meetingId, tagId])
                }
                let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.invalid", clientID: "test", createdAt: fixture.now)
                try connection.insert(db)
                try db.execute(
                    sql: "UPDATE workspaces SET accountConnectionId = ?, organizationId = COALESCE(organizationId, id), syncRole = 'admin', syncPullCursor = 'keep' WHERE id = ?",
                    arguments: [connection.id, other.workspace.id]
                )
                try db.execute(
                    sql: "INSERT INTO sync_transactions(id, workspace_id, connectionId, createdAt, availableAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [UUID.v7(), other.workspace.id, connection.id, fixture.now, fixture.now]
                )
            }
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let selected: Set<UUID> = [fixture.meeting.workspaceId, second.workspace.id, skipped.workspace.id]
            let generation = try await service.createGeneration(workspaceIds: selected)
            let metadata = try #require(generation.metadata)
            #expect(metadata.formatVersion == 5)
            #expect(Set(metadata.workspaces.map(\.id)) == selected)
            let backup = try DatabaseQueue(path: extractedBackupDatabase(generation.fileURL).path)
            try await backup.read { db throws in
                #expect(try WorkspaceRecord.fetchCount(db) == 3)
                #expect(try MeetingRecord.fetchCount(db) == 3)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_tags") == 2)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dahlia_account_connections") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_transactions") == 0)
            }
            try backup.close()
            let databaseURL = try makeLiveCopy(fixture)
            let freshID = UUID.v7()
            let requests = [
                WorkspaceBackupRestoreRequest(
                    sourceWorkspaceId: fixture.meeting.workspaceId,
                    targetWorkspaceId: fixture.meeting.workspaceId,
                    mode: .overwrite,
                    name: "Test"
                ),
                WorkspaceBackupRestoreRequest(sourceWorkspaceId: second.workspace.id, targetWorkspaceId: freshID, mode: .newWorkspace, name: "Same"),
            ]
            let marker = try await service.prepareRestore(from: generation, requests: requests)
            let decoded = try JSONDecoder.backupDecoder.decode(PendingDatabaseRestore.self, from: Data(contentsOf:
                BackupService.pendingRestoreURL(applicationSupportURL: fixture.testRootURL)))
            #expect(decoded == marker)
            let outcome = BackupRestoreStartupProcessor.applyPendingRestore(applicationSupportURL: fixture.testRootURL, databaseURL: databaseURL)
            guard case let .completed(results) = outcome,
                  results.allSatisfy({ $0.error == nil }) else { Issue.record("Mixed restore failed: \(outcome)")
                return
            }
            let result = try AppDatabaseManager(path: databaseURL.path)
            try await result.dbQueue.read { db throws in
                #expect(try WorkspaceRecord.fetchCount(db) == 5)
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id)?.name == fixture.meeting.name)
                for meeting in [second.meeting, skipped.meeting, other.meeting] {
                    #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.name == "Changed")
                }
                #expect(try MeetingRecord.filter(Column("workspace_id") == freshID).fetchOne(db)?.name == second.meeting.name)
                #expect(try WorkspaceRecord.fetchOne(db, key: other.workspace.id)?.syncPullCursor == "keep")
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_transactions") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_tags") == 3)
            }
            await result.searchIndexer.drain()
            let indexed = try await result.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents WHERE workspace_id = ?", arguments: [freshID]) ?? 0
            }
            #expect(indexed > 0)
            try result.close()
            let safety = try #require(try await service.listGenerations().first { $0.metadata?.reason == .beforeRestore })
            #expect(safety.metadata?.workspaces.map(\.id) == [fixture.meeting.workspaceId])
            for _ in 0 ..< 2 {
                _ = try await service.prepareRestore(from: generation, requests: metadata.workspaces.map {
                    WorkspaceBackupRestoreRequest(sourceWorkspaceId: $0.id, targetWorkspaceId: .v7(), mode: .newWorkspace, name: "Same")
                })
                let repeated = BackupRestoreStartupProcessor.applyPendingRestore(applicationSupportURL: fixture.testRootURL, databaseURL: databaseURL)
                guard case let .completed(results) = repeated,
                      results.allSatisfy({ $0.error == nil }) else { Issue.record("Repeated restore failed: \(repeated)")
                    return
                }
            }
            let repeatedResult = try AppDatabaseManager(path: databaseURL.path)
            defer { try? repeatedResult.close() }
            try await repeatedResult.dbQueue.read { db throws in
                #expect(try WorkspaceRecord.fetchCount(db) == 11)
                #expect(try MeetingRecord.fetchCount(db) == 11)
                try WorkspaceBackupTransfer.validateIntegrity(in: db)
            }
        }

        @Test(arguments: ["content", "missing", "synced", "safety"], [false, true])
        func failedWorkspaceRollsBackWhileOtherWorkspaceSucceeds(failure: String, failingFirst: Bool) async throws {
            let fixture = try BatchAudioTestFixture(name: "BatchFailure", endedAt: .now, batchCompletedAt: .now)
            defer { fixture.removeFiles() }
            let second = try addWorkspace(to: fixture, name: "Second")
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let generation = try await service.createGeneration(workspaceIds: [fixture.meeting.workspaceId, second.workspace.id])
            if failure == "content" {
                try editBackupDatabase(generation.fileURL) { db in
                    let trigger = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'projects_validate_parent_insert'")!
                    try db.execute(sql: "DROP TRIGGER projects_validate_parent_insert")
                    try ProjectRecord(
                        id: .v7(),
                        workspaceId: second.workspace.id,
                        parentProjectId: .v7(),
                        name: "Orphan",
                        createdAt: fixture.now,
                        projectType: nil
                    ).insert(db)
                    try db.execute(sql: trigger)
                }

            }
            let successfulTarget = failure == "safety" ? UUID.v7() : fixture.meeting.workspaceId
            var requests = [
                WorkspaceBackupRestoreRequest(
                    sourceWorkspaceId: fixture.meeting.workspaceId,
                    targetWorkspaceId: successfulTarget,
                    mode: failure == "safety" ? .newWorkspace : .overwrite,
                    name: "Test"
                ),
                WorkspaceBackupRestoreRequest(
                    sourceWorkspaceId: second.workspace.id,
                    targetWorkspaceId: second.workspace.id,
                    mode: .overwrite,
                    name: "Second"
                ),
            ]
            if failingFirst { requests.reverse() }
            _ = try await service.prepareRestore(from: generation, requests: requests)
            let databaseURL = try makeLiveCopy(fixture)
            let live = try AppDatabaseManager(path: databaseURL.path)
            try await live.dbQueue.write { db in
                if failure == "missing" { _ = try WorkspaceRecord.deleteOne(db, key: second.workspace.id) }
                if failure ==
                    "synced" { try db.execute(sql: "UPDATE workspaces SET syncRole = 'admin' WHERE id = ?", arguments: [second.workspace.id]) }
            }
            try live.close()
            if failure == "safety" {
                let directory = fixture.testRootURL.appending(path: BackupService.backupDirectoryName)
                try FileManager.default.removeItem(at: directory)
                try Data("blocks safety backup".utf8).write(to: directory)
            }
            let outcome = BackupRestoreStartupProcessor.applyPendingRestore(applicationSupportURL: fixture.testRootURL, databaseURL: databaseURL)
            guard case let .completed(results) = outcome else { Issue.record("Expected per-workspace results: \(outcome)")
                return
            }
            #expect(results.map(\.request) == requests)
            #expect(results.first { $0.request.targetWorkspaceId == successfulTarget }?.error == nil)
            #expect(results.first { $0.request.targetWorkspaceId == second.workspace.id }?.error != nil)
            let result = try AppDatabaseManager(path: databaseURL.path)
            defer { try? result.close() }
            try await result.dbQueue.read { db throws in
                #expect(try MeetingRecord.filter(Column("workspace_id") == successfulTarget).fetchOne(db)?.name == fixture.meeting.name)
                #expect(try MeetingRecord.fetchOne(db, key: second.meeting.id)?.name == (failure == "missing" ? nil : "Changed"))
                let expectedWorkspaceCount = switch failure {
                case "missing": 1
                case "safety": 3
                default: 2
                }
                #expect(try WorkspaceRecord.fetchCount(db) == expectedWorkspaceCount)
                #expect(try ProjectRecord.filter(Column("workspace_id") == second.workspace.id).fetchCount(db) == 0)
                try WorkspaceBackupTransfer.validateIntegrity(in: db)
            }
            if failure == "content" {
                let safety = try await service.listGenerations().filter { $0.metadata?.reason == .beforeRestore }
                #expect(safety.count == 2)
                #expect(Set(safety.flatMap { $0.metadata?.workspaces.map(\.id) ?? [] }) == [fixture.meeting.workspaceId, second.workspace.id])
            }
        }

        @Test
        func emptyDuplicateAndInvalidSelectionsCannotPublish() async throws {
            let fixture = try BatchAudioTestFixture(name: "InvalidSelection", endedAt: .now, batchCompletedAt: .now)
            defer { fixture.removeFiles() }
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            await #expect(throws: BackupServiceError.invalidBackup) { try await service.createGeneration(workspaceIds: []) }
            await #expect(throws: BackupServiceError.invalidBackup) {
                try await service.createGeneration(workspaceIds: [fixture.meeting.workspaceId, .v7()])
            }
            #expect(try await service.listGenerations().isEmpty)
            let generation = try await service.createGeneration(workspaceIds: [fixture.meeting.workspaceId])
            let request = WorkspaceBackupRestoreRequest(
                sourceWorkspaceId: fixture.meeting.workspaceId,
                targetWorkspaceId: .v7(),
                mode: .newWorkspace,
                name: "New"
            )
            for requests in [[], [request, request]] {
                await #expect(throws: BackupServiceError.invalidBackup) { try await service.prepareRestore(from: generation, requests: requests) }
            }
            let unknown = WorkspaceBackupRestoreRequest(sourceWorkspaceId: .v7(), targetWorkspaceId: .v7(), mode: .newWorkspace, name: "Unknown")
            await #expect(throws: BackupServiceError.invalidBackup) { try await service.prepareRestore(from: generation, requests: [unknown]) }
            #expect(!FileManager.default.fileExists(atPath: BackupService.pendingRestoreURL(applicationSupportURL: fixture.testRootURL).path))
            try editBackupDatabase(generation.fileURL) { db in
                try db.execute(sql: "UPDATE dahlia_backup_metadata SET workspacesJSON = ?", arguments: ["[]"])
            }

            await #expect(throws: BackupServiceError.invalidBackup) { try await service.importGeneration(from: generation.fileURL) }
        }

        @Test
        func restoreResultsIdentifySameNameSourceWorkspaces() throws {
            let targetId = try #require(UUID(uuidString: "019A0000-0000-7000-8000-000033333333"))
            for suffix in ["11111111", "22222222"] {
                let sourceId = try #require(UUID(uuidString: "019A0000-0000-7000-8000-0000\(suffix)"))
                let request = WorkspaceBackupRestoreRequest(
                    sourceWorkspaceId: sourceId,
                    targetWorkspaceId: targetId,
                    mode: .newWorkspace,
                    name: "Same"
                )
                for error in [nil, "Failure"] as [String?] {
                    let message = WorkspaceBackupRestoreResult(request: request, error: error).localizedMessage
                    #expect(message.contains(suffix))
                    #expect(!message.contains("33333333"))
                }
            }
        }

        @Test
        func settingsKeepsExplicitSelectionAndRequiresPerWorkspaceRestoreChoice() async throws {
            let fixture = try BatchAudioTestFixture(name: "MultiSettings", endedAt: .now, batchCompletedAt: .now)
            defer { fixture.removeFiles() }
            let second = try addWorkspace(to: fixture, name: "Second")
            let model = BackupSettingsViewModel(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            model.selectedWorkspaceIds = [fixture.meeting.workspaceId, second.workspace.id]
            await model.refresh()
            await model.createBackup()
            let metadata = try #require(model.generations.first?.metadata)
            #expect(metadata.workspaces.count == 2)
            model.selectedWorkspaceIds.removeAll()
            await model.refresh()
            #expect(model.selectedWorkspaceIds.isEmpty)
            model.beginRestore(metadata)
            #expect(model.restoreSelections.allSatisfy { $0.mode == nil })
            #expect(!model.canRestore)
            model.restoreSelections[0].mode = .overwrite
            model.restoreSelections[1].mode = .newWorkspace
            #expect(model.canRestore)
            model.restoreSelections[1].name = " "
            #expect(!model.canRestore)
            model.restoreSelections[1].name = "Restored"
            #expect(model.canRestore)
            let overwrittenId = model.restoreSelections[0].id
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "UPDATE workspaces SET syncRole = 'admin' WHERE id = ?", arguments: [overwrittenId])
            }
            await model.refresh()
            #expect(!model.canRestore)
            model.restoreSelections[0].mode = nil
            #expect(model.canRestore)
        }

        private func addWorkspace(to fixture: BatchAudioTestFixture, name: String) throws -> (workspace: WorkspaceRecord, meeting: MeetingRecord) {
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: name, createdAt: fixture.now, lastOpenedAt: fixture.now)
            var meeting = fixture.meeting
            meeting.id = .v7()
            meeting.workspaceId = workspace.id
            meeting.name = name
            try fixture.database.dbQueue.write { db in
                try workspace.insert(db)
                try meeting.insert(db)
            }
            return (workspace, meeting)
        }

        private func makeLiveCopy(_ fixture: BatchAudioTestFixture) throws -> URL {
            let url = fixture.testRootURL.appending(path: "live.sqlite")
            let live = try AppDatabaseManager(path: url.path, enablesConcurrentSearch: true)
            try fixture.database.dbQueue.backup(to: live.dbQueue)
            try live.dbQueue.write { try $0.execute(sql: "UPDATE meetings SET name = 'Changed'") }
            try live.close()
            return url
        }
    }
#endif
