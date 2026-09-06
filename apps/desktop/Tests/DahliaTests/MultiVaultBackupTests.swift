import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MultiVaultBackupTests {
        @Test
        func mixedRestorePreservesSkippedVaultsAndSharedTags() async throws {
            let fixture = try BatchAudioTestFixture(name: "MultiVault", endedAt: .now, batchCompletedAt: .now)
            defer { fixture.removeFiles() }
            let second = try addVault(to: fixture, name: "Same")
            let skipped = try addVault(to: fixture, name: "Same")
            let other = try addVault(to: fixture, name: "Excluded")
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "INSERT INTO tags(name, colorHex, createdAt) VALUES ('Shared', '#000000', ?)", arguments: [fixture.now])
                let tagId = db.lastInsertedRowID
                for meetingId in [fixture.meeting.id, second.meeting.id] {
                    try db.execute(sql: "INSERT INTO meeting_tags(meetingId, tagId) VALUES (?, ?)", arguments: [meetingId, tagId])
                }
                let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.invalid", clientID: "test", createdAt: fixture.now)
                try connection.insert(db)
                try db.execute(
                    sql: "UPDATE vaults SET accountConnectionId = ?, syncRole = 'owner', syncPullCursor = 'keep' WHERE id = ?",
                    arguments: [connection.id, other.vault.id]
                )
                try db.execute(
                    sql: "INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [UUID.v7(), other.vault.id, connection.id, fixture.now, fixture.now]
                )
            }
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let selected: Set<UUID> = [fixture.meeting.vaultId, second.vault.id, skipped.vault.id]
            let generation = try await service.createGeneration(vaultIds: selected)
            let metadata = try #require(generation.metadata)
            #expect(metadata.formatVersion == 3)
            #expect(Set(metadata.vaults.map(\.id)) == selected)
            let backup = try DatabaseQueue(path: generation.fileURL.path)
            try await backup.read { db throws in
                #expect(try VaultRecord.fetchCount(db) == 3)
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
                VaultBackupRestoreRequest(
                    sourceVaultId: fixture.meeting.vaultId,
                    targetVaultId: fixture.meeting.vaultId,
                    mode: .overwrite,
                    name: "Test"
                ),
                VaultBackupRestoreRequest(sourceVaultId: second.vault.id, targetVaultId: freshID, mode: .newVault, name: "Same"),
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
                #expect(try VaultRecord.fetchCount(db) == 5)
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id)?.name == fixture.meeting.name)
                for meeting in [second.meeting, skipped.meeting, other.meeting] {
                    #expect(try MeetingRecord.fetchOne(db, key: meeting.id)?.name == "Changed")
                }
                #expect(try MeetingRecord.filter(Column("vaultId") == freshID).fetchOne(db)?.name == second.meeting.name)
                #expect(try VaultRecord.fetchOne(db, key: other.vault.id)?.syncPullCursor == "keep")
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_transactions") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_tags") == 3)
            }
            await result.searchIndexer.drain()
            let indexed = try await result.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents WHERE vaultId = ?", arguments: [freshID]) ?? 0
            }
            #expect(indexed > 0)
            try result.close()
            let safety = try #require(try await service.listGenerations().first { $0.metadata?.reason == .beforeRestore })
            #expect(safety.metadata?.vaults.map(\.id) == [fixture.meeting.vaultId])
            for _ in 0 ..< 2 {
                _ = try await service.prepareRestore(from: generation, requests: metadata.vaults.map {
                    VaultBackupRestoreRequest(sourceVaultId: $0.id, targetVaultId: .v7(), mode: .newVault, name: "Same")
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
                #expect(try VaultRecord.fetchCount(db) == 11)
                #expect(try MeetingRecord.fetchCount(db) == 11)
                try VaultBackupTransfer.validateIntegrity(in: db)
            }
        }

        @Test(arguments: ["content", "missing", "synced", "safety"], [false, true])
        func failedVaultRollsBackWhileOtherVaultSucceeds(failure: String, failingFirst: Bool) async throws {
            let fixture = try BatchAudioTestFixture(name: "BatchFailure", endedAt: .now, batchCompletedAt: .now)
            defer { fixture.removeFiles() }
            let second = try addVault(to: fixture, name: "Second")
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId, second.vault.id])
            if failure == "content" {
                let editable = try DatabaseQueue(path: generation.fileURL.path, configuration: AppDatabaseManager.configuration())
                try await editable.write { db in
                    let trigger = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'projects_validate_parent_insert'")!
                    try db.execute(sql: "DROP TRIGGER projects_validate_parent_insert")
                    try ProjectRecord(
                        id: .v7(),
                        vaultId: second.vault.id,
                        parentProjectId: .v7(),
                        name: "Orphan",
                        createdAt: fixture.now,
                        projectType: nil
                    ).insert(db)
                    try db.execute(sql: trigger)
                }
                try editable.close()
            }
            let successfulTarget = failure == "safety" ? UUID.v7() : fixture.meeting.vaultId
            var requests = [
                VaultBackupRestoreRequest(
                    sourceVaultId: fixture.meeting.vaultId,
                    targetVaultId: successfulTarget,
                    mode: failure == "safety" ? .newVault : .overwrite,
                    name: "Test"
                ),
                VaultBackupRestoreRequest(sourceVaultId: second.vault.id, targetVaultId: second.vault.id, mode: .overwrite, name: "Second"),
            ]
            if failingFirst { requests.reverse() }
            _ = try await service.prepareRestore(from: generation, requests: requests)
            let databaseURL = try makeLiveCopy(fixture)
            let live = try AppDatabaseManager(path: databaseURL.path)
            try await live.dbQueue.write { db in
                if failure == "missing" { _ = try VaultRecord.deleteOne(db, key: second.vault.id) }
                if failure == "synced" { try db.execute(sql: "UPDATE vaults SET syncRole = 'owner' WHERE id = ?", arguments: [second.vault.id]) }
            }
            try live.close()
            if failure == "safety" {
                let directory = fixture.testRootURL.appending(path: BackupService.backupDirectoryName)
                try FileManager.default.removeItem(at: directory)
                try Data("blocks safety backup".utf8).write(to: directory)
            }
            let outcome = BackupRestoreStartupProcessor.applyPendingRestore(applicationSupportURL: fixture.testRootURL, databaseURL: databaseURL)
            guard case let .completed(results) = outcome else { Issue.record("Expected per-vault results: \(outcome)")
                return
            }
            #expect(results.map(\.request) == requests)
            #expect(results.first { $0.request.targetVaultId == successfulTarget }?.error == nil)
            #expect(results.first { $0.request.targetVaultId == second.vault.id }?.error != nil)
            let result = try AppDatabaseManager(path: databaseURL.path)
            defer { try? result.close() }
            try await result.dbQueue.read { db throws in
                #expect(try MeetingRecord.filter(Column("vaultId") == successfulTarget).fetchOne(db)?.name == fixture.meeting.name)
                #expect(try MeetingRecord.fetchOne(db, key: second.meeting.id)?.name == (failure == "missing" ? nil : "Changed"))
                let expectedVaultCount = switch failure {
                case "missing": 1
                case "safety": 3
                default: 2
                }
                #expect(try VaultRecord.fetchCount(db) == expectedVaultCount)
                #expect(try ProjectRecord.filter(Column("vaultId") == second.vault.id).fetchCount(db) == 0)
                try VaultBackupTransfer.validateIntegrity(in: db)
            }
            if failure == "content" {
                let safety = try await service.listGenerations().filter { $0.metadata?.reason == .beforeRestore }
                #expect(safety.count == 2)
                #expect(Set(safety.flatMap { $0.metadata?.vaults.map(\.id) ?? [] }) == [fixture.meeting.vaultId, second.vault.id])
            }
        }

        @Test
        func emptyDuplicateAndInvalidSelectionsCannotPublish() async throws {
            let fixture = try BatchAudioTestFixture(name: "InvalidSelection", endedAt: .now, batchCompletedAt: .now)
            defer { fixture.removeFiles() }
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            await #expect(throws: BackupServiceError.invalidBackup) { try await service.createGeneration(vaultIds: []) }
            await #expect(throws: BackupServiceError.invalidBackup) { try await service.createGeneration(vaultIds: [fixture.meeting.vaultId, .v7()]) }
            #expect(try await service.listGenerations().isEmpty)
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
            let request = VaultBackupRestoreRequest(sourceVaultId: fixture.meeting.vaultId, targetVaultId: .v7(), mode: .newVault, name: "New")
            for requests in [[], [request, request]] {
                await #expect(throws: BackupServiceError.invalidBackup) { try await service.prepareRestore(from: generation, requests: requests) }
            }
            let unknown = VaultBackupRestoreRequest(sourceVaultId: .v7(), targetVaultId: .v7(), mode: .newVault, name: "Unknown")
            await #expect(throws: BackupServiceError.invalidBackup) { try await service.prepareRestore(from: generation, requests: [unknown]) }
            #expect(!FileManager.default.fileExists(atPath: BackupService.pendingRestoreURL(applicationSupportURL: fixture.testRootURL).path))
            let editable = try DatabaseQueue(path: generation.fileURL.path)
            try await editable.write { db in
                try db.execute(sql: "UPDATE dahlia_backup_metadata SET vaultsJSON = ?", arguments: ["[]"])
            }
            try editable.close()
            await #expect(throws: BackupServiceError.invalidBackup) { try await service.importGeneration(from: generation.fileURL) }
        }

        @Test
        func settingsKeepsExplicitSelectionAndRequiresPerVaultRestoreChoice() async throws {
            let fixture = try BatchAudioTestFixture(name: "MultiSettings", endedAt: .now, batchCompletedAt: .now)
            defer { fixture.removeFiles() }
            let second = try addVault(to: fixture, name: "Second")
            let model = BackupSettingsViewModel(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            model.selectedVaultIds = [fixture.meeting.vaultId, second.vault.id]
            await model.refresh()
            await model.createBackup()
            let metadata = try #require(model.generations.first?.metadata)
            #expect(metadata.vaults.count == 2)
            model.selectedVaultIds.removeAll()
            await model.refresh()
            #expect(model.selectedVaultIds.isEmpty)
            model.beginRestore(metadata)
            #expect(model.restoreSelections.allSatisfy { $0.mode == nil })
            #expect(!model.canRestore)
            model.restoreSelections[0].mode = .overwrite
            model.restoreSelections[1].mode = .newVault
            #expect(model.canRestore)
            model.restoreSelections[1].name = " "
            #expect(!model.canRestore)
            model.restoreSelections[1].name = "Restored"
            #expect(model.canRestore)
            let overwrittenId = model.restoreSelections[0].id
            try await fixture.database.dbQueue.write { db in
                try db.execute(sql: "UPDATE vaults SET syncRole = 'owner' WHERE id = ?", arguments: [overwrittenId])
            }
            await model.refresh()
            #expect(!model.canRestore)
            model.restoreSelections[0].mode = nil
            #expect(model.canRestore)
        }

        private func addVault(to fixture: BatchAudioTestFixture, name: String) throws -> (vault: VaultRecord, meeting: MeetingRecord) {
            let vault = VaultRecord(id: .v7(), path: nil, name: name, createdAt: fixture.now, lastOpenedAt: fixture.now)
            var meeting = fixture.meeting
            meeting.id = .v7()
            meeting.vaultId = vault.id
            meeting.name = name
            try fixture.database.dbQueue.write { db in
                try vault.insert(db)
                try meeting.insert(db)
            }
            return (vault, meeting)
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
