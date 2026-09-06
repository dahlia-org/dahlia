import AppKit
import DahliaRuntimeSupport
import Foundation
import GRDB

enum BackupRestoreStartupOutcome: Equatable, Sendable {
    case none
    case completed([VaultBackupRestoreResult])
    case failed(String)
}

struct VaultBackupRestoreResult: Equatable, Sendable {
    let request: VaultBackupRestoreRequest
    let error: String?

    var localizedMessage: String {
        if let error {
            L10n.backupVaultRestoreFailed(request.name, sourceVaultId: request.sourceVaultId, reason: error)
        } else {
            L10n.backupVaultRestored(request.name, sourceVaultId: request.sourceVaultId)
        }
    }
}

enum BackupRestoreStartupProcessor {
    static let recoveryFilename = "dahlia.restore-original.sqlite"
    static let installingFilename = "dahlia.restore-installing.sqlite"

    static func applyPendingRestore(
        applicationSupportURL: URL = DahliaApplicationSupport.currentDirectoryURL,
        databaseURL: URL = AppDatabaseManager.databaseURL,
        fileManager: FileManager = .default
    ) -> BackupRestoreStartupOutcome {
        let markerURL = BackupService.pendingRestoreURL(applicationSupportURL: applicationSupportURL)
        do {
            try recoverInterruptedInstall(databaseURL: databaseURL, fileManager: fileManager)
        } catch {
            return .failed(error.localizedDescription)
        }
        guard fileManager.fileExists(atPath: markerURL.path) else { return .none }

        let restoreDirectoryURL = markerURL.deletingLastPathComponent().standardizedFileURL
        var stagedURL: URL?
        do {
            let marker = try JSONDecoder.backupDecoder.decode(
                PendingDatabaseRestore.self,
                from: Data(contentsOf: markerURL)
            )
            guard !marker.stagedFilename.isEmpty,
                  !marker.stagedFilename.contains("/"),
                  !marker.stagedFilename.contains(":") else {
                throw BackupServiceError.invalidBackup
            }
            let candidateURL = restoreDirectoryURL.appending(path: marker.stagedFilename).standardizedFileURL
            guard candidateURL.deletingLastPathComponent() == restoreDirectoryURL,
                  candidateURL.resolvingSymlinksInPath().deletingLastPathComponent()
                  == restoreDirectoryURL.resolvingSymlinksInPath() else {
                throw BackupServiceError.invalidBackup
            }
            stagedURL = candidateURL
            let values = try candidateURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  try BackupService.sha256(of: candidateURL) == marker.sha256 else {
                throw BackupServiceError.invalidBackup
            }

            let combinedURL = restoreDirectoryURL.appending(path: "combined-\(UUID.v7()).sqlite")
            defer { try? fileManager.removeItem(at: combinedURL) }
            let results = try mergeVaults(
                marker: marker,
                sourceURL: candidateURL,
                databaseURL: databaseURL,
                combinedURL: combinedURL,
                applicationSupportURL: applicationSupportURL
            )
            if results.contains(where: { $0.error == nil }) {
                try install(stagedURL: combinedURL, databaseURL: databaseURL, fileManager: fileManager)
            }

            try? fileManager.removeItem(at: markerURL)
            try? fileManager.removeItem(at: candidateURL)
            return .completed(results)
        } catch {
            try? fileManager.removeItem(at: markerURL)
            if let stagedURL {
                try? fileManager.removeItem(at: stagedURL)
            }
            return .failed(error.localizedDescription)
        }
    }

    private static func mergeVaults(
        marker: PendingDatabaseRestore,
        sourceURL: URL,
        databaseURL: URL,
        combinedURL: URL,
        applicationSupportURL: URL
    ) throws -> [VaultBackupRestoreResult] {
        let metadata = try BackupService.readAndValidateMetadata(at: sourceURL)
        let requests = marker.requests
        guard metadata == marker.sourceMetadata,
              !requests.isEmpty,
              Set(requests.map(\.sourceVaultId)).count == requests.count,
              Set(requests.map(\.targetVaultId)).count == requests.count else { throw BackupServiceError.invalidBackup }
        // Migrate only a managed copy; retain the original generation and staged checksum for retry.
        let migratedURL = sourceURL.deletingLastPathComponent().appending(path: "migrated-\(UUID.v7()).sqlite")
        defer { try? FileManager.default.removeItem(at: migratedURL) }
        try FileManager.default.copyItem(at: sourceURL, to: migratedURL)
        let migrated = try AppDatabaseManager(path: migratedURL.path)
        defer { try? migrated.close() }
        try migrated.dbQueue.read { db in
            guard try AppDatabaseManager.hasExpectedCurrentSchema(db, excludingTableNames: [BackupService.metadataTableName]) else {
                throw BackupServiceError.invalidBackup
            }
            try VaultBackupTransfer.validateIntegrity(in: db)
        }
        try migrated.close()
        let current = try DatabaseQueue(path: databaseURL.path, configuration: AppDatabaseManager.configuration())
        defer { try? current.close() }
        let combined = try AppDatabaseManager(path: combinedURL.path)
        defer { try? combined.close() }
        try current.backup(to: combined.dbQueue)
        try current.close()
        try combined.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS backup_source", arguments: [migratedURL.path])
        }
        var results: [VaultBackupRestoreResult] = []
        for request in requests {
            do {
                let target = try combined.dbQueue.read { db in
                    try BackupService.validateRestoreRequests([request], metadata: metadata, in: db)[request.targetVaultId]
                }
                if let target {
                    _ = try BackupService.createGeneration(
                        vaultIds: [target.id], dbQueue: combined.dbQueue,
                        directoryURL: applicationSupportURL.appending(path: BackupService.backupDirectoryName),
                        reason: .beforeRestore,
                        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                        appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
                    )
                }
                try combined.dbQueue.write { db in
                    guard let original = try VaultRecord.fetchOne(
                        db,
                        sql: "SELECT * FROM backup_source.vaults WHERE id = ?",
                        arguments: [request.sourceVaultId]
                    ) else {
                        throw BackupServiceError.invalidBackup
                    }
                    var restoredVault = VaultBackupTransfer.portableVault(original)
                    if let target {
                        restoredVault.path = target.path
                        restoredVault.accountConnectionId = target.accountConnectionId
                        restoredVault.localAIProvider = target.localAIProvider
                        restoredVault.databricksProfile = target.databricksProfile
                        restoredVault.summaryModelID = target.summaryModelID
                        restoredVault.summaryReasoningEffort = target.summaryReasoningEffort
                        restoredVault.chatModelID = target.chatModelID
                        restoredVault.chatReasoningEffort = target.chatReasoningEffort
                    } else {
                        restoredVault.id = request.targetVaultId
                        restoredVault.name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        restoredVault.createdAt = .now
                        restoredVault.lastOpenedAt = .now
                    }
                    let retainedAudio = target == nil ? [] : try VaultBackupTransfer.retainedAudio(vaultId: request.targetVaultId, in: db)
                    if target != nil { try VaultBackupTransfer.removeVaultContent(id: request.targetVaultId, in: db) }
                    try VaultBackupTransfer.copy(
                        vaultId: request.sourceVaultId,
                        in: db,
                        destinationVault: restoredVault,
                        remapIDs: request.mode == .newVault
                    )
                    try VaultBackupTransfer.restoreRetainedAudio(retainedAudio, in: db)
                    try VaultBackupTransfer.validateIntegrity(in: db)
                }
                results.append(VaultBackupRestoreResult(request: request, error: nil))
            } catch {
                results.append(VaultBackupRestoreResult(request: request, error: error.localizedDescription))
            }
        }
        try combined.dbQueue.writeWithoutTransaction { db in
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
        }
        try combined.close()
        return results
    }

    private static func install(stagedURL: URL, databaseURL: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try validateRestoredDatabase(at: stagedURL)

        let directoryURL = databaseURL.deletingLastPathComponent()
        let recoveryURL = directoryURL.appending(path: recoveryFilename)
        let installingURL = directoryURL.appending(path: installingFilename)
        try? fileManager.removeItem(at: installingURL)
        try fileManager.copyItem(at: stagedURL, to: installingURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: installingURL.path)
        try validateRestoredDatabase(at: installingURL)

        guard fileManager.fileExists(atPath: databaseURL.path) else {
            try fileManager.moveItem(at: installingURL, to: databaseURL)
            do {
                try validateRestoredDatabase(at: databaseURL)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
            } catch {
                try? fileManager.removeItem(at: databaseURL)
                throw error
            }
            return
        }

        try checkpointAndRemoveSQLiteSidecars(for: databaseURL, fileManager: fileManager)
        do {
            try fileManager.moveItem(at: databaseURL, to: recoveryURL)
            try fileManager.moveItem(at: installingURL, to: databaseURL)
        } catch {
            if !fileManager.fileExists(atPath: databaseURL.path),
               fileManager.fileExists(atPath: recoveryURL.path) {
                try? fileManager.moveItem(at: recoveryURL, to: databaseURL)
            }
            throw error
        }

        do {
            try validateRestoredDatabase(at: databaseURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
            try? fileManager.removeItem(at: recoveryURL)
        } catch {
            if fileManager.fileExists(atPath: recoveryURL.path) {
                try? fileManager.removeItem(at: databaseURL)
                try fileManager.moveItem(at: recoveryURL, to: databaseURL)
            }
            throw error
        }
    }

    private static func recoverInterruptedInstall(databaseURL: URL, fileManager: FileManager) throws {
        let directoryURL = databaseURL.deletingLastPathComponent()
        let recoveryURL = directoryURL.appending(path: recoveryFilename)
        let installingURL = directoryURL.appending(path: installingFilename)
        defer { try? fileManager.removeItem(at: installingURL) }
        guard fileManager.fileExists(atPath: recoveryURL.path) else { return }

        if fileManager.fileExists(atPath: databaseURL.path) {
            try fileManager.removeItem(at: databaseURL)
        }
        try fileManager.moveItem(at: recoveryURL, to: databaseURL)
        try validateRestoredDatabase(at: databaseURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
    }

    private static func validateRestoredDatabase(at url: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? queue.close() }
        try queue.read { db in
            let quickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
            guard quickCheck == "ok",
                  try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty,
                  try AppDatabaseManager.migrator.hasCompletedMigrations(db),
                  try !AppDatabaseManager.migrator.hasBeenSuperseded(db),
                  try !db.tableExists(BackupService.metadataTableName),
                  try AppDatabaseManager.hasExpectedCurrentSchema(db) else {
                throw BackupServiceError.integrityCheckFailed(quickCheck)
            }
        }
    }

    private static func checkpointAndRemoveSQLiteSidecars(
        for databaseURL: URL,
        fileManager: FileManager
    ) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try queue.writeWithoutTransaction { db in
            _ = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try queue.close()
        for suffix in ["-wal", "-shm"] {
            let sidecarURL = URL(fileURLWithPath: databaseURL.path + suffix)
            if fileManager.fileExists(atPath: sidecarURL.path) {
                try fileManager.removeItem(at: sidecarURL)
            }
        }
    }

}

@MainActor
enum BackupRelaunchCoordinator {
    static func relaunchAfterTermination() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
            "dahlia-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path,
        ]
        do {
            try process.run()
            NSApplication.shared.terminate(nil)
        } catch {
            AppDelegate.cancelBackupRestorePreparation()
            ErrorReportingService.capture(error, context: ["source": "backupRestoreRelaunch"])
        }
    }
}
