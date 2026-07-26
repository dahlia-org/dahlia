import AppKit
import DahliaRuntimeSupport
import Foundation
import GRDB

enum BackupRestoreStartupOutcome: Equatable, Sendable {
    case none
    case restored(BackupMetadata)
    case failed(String)
}

enum BackupRestoreStartupProcessor {
    static let recoveryFilename = "dahlia.restore-original.sqlite"
    static let installingFilename = "dahlia.restore-installing.sqlite"

    static func applyPendingRestore(
        applicationSupportURL: URL = DahliaApplicationSupport.currentDirectoryURL,
        databaseURL: URL = AppDatabaseManager.databaseURL,
        audioRootURL: URL = BatchAudioStorage.managedRootURL,
        fileManager: FileManager = .default,
        audioCleanup: (URL, FileManager) -> Void = trashManagedAudio
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

            try install(stagedURL: candidateURL, databaseURL: databaseURL, fileManager: fileManager)

            try? fileManager.removeItem(at: markerURL)
            try? fileManager.removeItem(at: candidateURL)
            audioCleanup(audioRootURL, fileManager)
            return .restored(marker.sourceMetadata)
        } catch {
            try? fileManager.removeItem(at: markerURL)
            if let stagedURL {
                try? fileManager.removeItem(at: stagedURL)
            }
            return .failed(error.localizedDescription)
        }
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
        let queue = try DatabaseQueue(path: databaseURL.path)
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

    private static func trashManagedAudio(_ audioRootURL: URL, _ fileManager: FileManager) {
        guard fileManager.fileExists(atPath: audioRootURL.path) else { return }
        var resultingURL: NSURL?
        do {
            try fileManager.trashItem(at: audioRootURL, resultingItemURL: &resultingURL)
        } catch {
            ErrorReportingService.capture(error, context: ["source": "backupRestoreAudioCleanup"])
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
