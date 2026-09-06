import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct BackupRestoreStartupProcessorTests {
        @Test
        // swiftlint:disable:next function_body_length
        func failedRestoreCheckpointsCommittedWALBeforeRollingBack() throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-restore-wal-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let databaseURL = rootURL.appending(path: "dahlia.sqlite")
            let snapshotURL = rootURL.appending(path: "wal-snapshot", directoryHint: .isDirectory)
            let restoreDirectoryURL = rootURL.appending(path: BackupService.restoreDirectoryName)
            let stagedURL = restoreDirectoryURL.appending(path: "staged.sqlite")
            try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: restoreDirectoryURL, withIntermediateDirectories: true)

            let initial = try AppDatabaseManager(path: databaseURL.path)
            try initial.dbQueue.write { db in
                try makeVault(name: "Main", path: rootURL.appending(path: "MainVault").path).insert(db)
            }
            try initial.close()

            let walQueue = try DatabaseQueue(path: databaseURL.path)
            try walQueue.writeWithoutTransaction { db in
                _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
                try makeVault(name: "Committed WAL", path: rootURL.appending(path: "WALVault").path).insert(db)
            }
            let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
            #expect(FileManager.default.fileExists(atPath: walURL.path))
            let savedMainURL = snapshotURL.appending(path: "main.sqlite")
            let savedWALURL = snapshotURL.appending(path: "main.sqlite-wal")
            try FileManager.default.copyItem(at: databaseURL, to: savedMainURL)
            try FileManager.default.copyItem(at: walURL, to: savedWALURL)
            try walQueue.close()

            for url in [databaseURL, walURL, URL(fileURLWithPath: databaseURL.path + "-shm")] {
                try? FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: savedMainURL, to: databaseURL)
            try FileManager.default.copyItem(at: savedWALURL, to: walURL)
            try Data("not sqlite".utf8).write(to: stagedURL)
            try writeMarker(stagedURL: stagedURL, restoreDirectoryURL: restoreDirectoryURL)

            let outcome = BackupRestoreStartupProcessor.applyPendingRestore(
                applicationSupportURL: rootURL,
                databaseURL: databaseURL
            )
            guard case .failed = outcome else {
                Issue.record("Expected restore failure, got \(outcome)")
                return
            }
            let reopened = try AppDatabaseManager(path: databaseURL.path)
            let names = try reopened.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM vaults ORDER BY name")
            }
            #expect(names == ["Committed WAL", "Main"])
        }

        @Test
        func recoversOriginalDatabaseLeftByInterruptedInstall() throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-restore-interrupted-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let databaseURL = rootURL.appending(path: "dahlia.sqlite")
            let recoveryURL = rootURL.appending(path: BackupRestoreStartupProcessor.recoveryFilename)
            let current = try AppDatabaseManager(path: databaseURL.path)
            try current.dbQueue.write { db in
                try makeVault(name: "Unverified", path: rootURL.appending(path: "UnverifiedVault").path).insert(db)
            }
            try current.close()
            let recovery = try AppDatabaseManager(path: recoveryURL.path)
            try recovery.dbQueue.write { db in
                try makeVault(name: "Original", path: rootURL.appending(path: "OriginalVault").path).insert(db)
            }
            try recovery.close()

            let outcome = BackupRestoreStartupProcessor.applyPendingRestore(
                applicationSupportURL: rootURL,
                databaseURL: databaseURL
            )

            #expect(outcome == .none)
            let reopened = try AppDatabaseManager(path: databaseURL.path)
            let names = try reopened.dbQueue.read { db in try String.fetchAll(db, sql: "SELECT name FROM vaults") }
            #expect(names == ["Original"])
            #expect(!FileManager.default.fileExists(atPath: recoveryURL.path))
        }

        @Test
        func checksumMismatchRemovesPendingMarkerAndStagingFile() throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-restore-checksum-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let restoreDirectoryURL = rootURL.appending(path: BackupService.restoreDirectoryName)
            let stagedURL = restoreDirectoryURL.appending(path: "staged.sqlite")
            try FileManager.default.createDirectory(at: restoreDirectoryURL, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: stagedURL)
            try writeMarker(stagedURL: stagedURL, restoreDirectoryURL: restoreDirectoryURL)
            try Data("tampered".utf8).write(to: stagedURL)

            let outcome = BackupRestoreStartupProcessor.applyPendingRestore(
                applicationSupportURL: rootURL,
                databaseURL: rootURL.appending(path: "dahlia.sqlite")
            )

            guard case .failed = outcome else {
                Issue.record("Expected restore failure, got \(outcome)")
                return
            }
            #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
            #expect(!FileManager.default.fileExists(
                atPath: BackupService.pendingRestoreURL(applicationSupportURL: rootURL).path
            ))
        }

        @Test
        func invalidStagingDatabaseLeavesCurrentDatabaseIntact() throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-restore-rollback-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let databaseURL = rootURL.appending(path: "dahlia.sqlite")
            let restoreDirectoryURL = rootURL.appending(path: BackupService.restoreDirectoryName, directoryHint: .isDirectory)
            let stagedURL = restoreDirectoryURL.appending(path: "staged.sqlite")
            try FileManager.default.createDirectory(at: restoreDirectoryURL, withIntermediateDirectories: true)

            let current = try AppDatabaseManager(path: databaseURL.path)
            try current.dbQueue.write { db in
                try makeVault(name: "Current", path: rootURL.appending(path: "CurrentVault").path).insert(db)
            }
            try current.close()
            try Data("not sqlite".utf8).write(to: stagedURL)
            try writeMarker(stagedURL: stagedURL, restoreDirectoryURL: restoreDirectoryURL)

            let outcome = BackupRestoreStartupProcessor.applyPendingRestore(
                applicationSupportURL: rootURL,
                databaseURL: databaseURL
            )

            guard case .failed = outcome else {
                Issue.record("Expected restore failure, got \(outcome)")
                return
            }
            let reopened = try AppDatabaseManager(path: databaseURL.path)
            let names = try reopened.dbQueue.read { db in try String.fetchAll(db, sql: "SELECT name FROM vaults") }
            #expect(names == ["Current"])
        }

        private func makeVault(name: String, path: String) -> VaultRecord {
            VaultRecord(id: .v7(), path: path, name: name, createdAt: .now, lastOpenedAt: .now)
        }

        private func writeMarker(stagedURL: URL, restoreDirectoryURL: URL) throws {
            let metadata = BackupMetadata(
                formatVersion: BackupMetadata.currentFormatVersion,
                generationId: .v7(),
                createdAt: .now,
                schemaVersion: AppDatabaseManager.currentSchemaVersion,
                migrationIdentifier: AppDatabaseManager.currentMigrationIdentifier,
                appVersion: "1.2.3",
                appBuild: "45",
                reason: .manual, vaults: [BackupVault(id: .v7(), name: "Test")]
            )
            let marker = try PendingDatabaseRestore(
                stagedFilename: stagedURL.lastPathComponent,
                sha256: BackupService.sha256(of: stagedURL),
                requestedAt: .now,
                sourceMetadata: metadata,
                requests: [VaultBackupRestoreRequest(sourceVaultId: metadata.vaults[0].id, targetVaultId: .v7(), mode: .newVault, name: "Restored")]
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .deferredToDate
            try encoder.encode(marker).write(
                to: restoreDirectoryURL.appending(path: BackupService.pendingRestoreFilename),
                options: [.atomic]
            )
        }
    }
#endif
