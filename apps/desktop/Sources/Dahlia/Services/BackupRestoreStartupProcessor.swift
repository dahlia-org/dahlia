import AppKit
import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB

enum BackupRestoreStartupOutcome: Equatable, Sendable {
    case none
    case completed([WorkspaceBackupRestoreResult])
    case failed(String)
}

struct WorkspaceBackupRestoreResult: Equatable, Sendable {
    let request: WorkspaceBackupRestoreRequest
    let error: String?

    var localizedMessage: String {
        if let error {
            L10n.backupWorkspaceRestoreFailed(request.name, sourceWorkspaceId: request.sourceWorkspaceId, reason: error)
        } else {
            L10n.backupWorkspaceRestored(request.name, sourceWorkspaceId: request.sourceWorkspaceId)
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
            let results: [WorkspaceBackupRestoreResult] = if try BackupArchive.isArchive(candidateURL) {
                try BackupArchive.withExtracted(at: candidateURL) { directory, manifest in
                    guard manifest.metadata == marker.sourceMetadata else { throw BackupServiceError.invalidBackup }
                    return try mergeWorkspaces(
                        marker: marker,
                        sourceURL: directory.appending(path: "database.sqlite"),
                        databaseURL: databaseURL,
                        combinedURL: combinedURL,
                        applicationSupportURL: applicationSupportURL,
                        archiveDirectory: directory
                    )
                }
            } else {
                try mergeWorkspaces(
                    marker: marker,
                    sourceURL: candidateURL,
                    databaseURL: databaseURL,
                    combinedURL: combinedURL,
                    applicationSupportURL: applicationSupportURL
                )
            }
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

    private static func mergeWorkspaces(
        marker: PendingDatabaseRestore,
        sourceURL: URL,
        databaseURL: URL,
        combinedURL: URL,
        applicationSupportURL: URL,
        archiveDirectory: URL? = nil
    ) throws -> [WorkspaceBackupRestoreResult] {
        let metadata = try BackupService.readAndValidateMetadata(at: sourceURL)
        let requests = marker.requests
        guard metadata == marker.sourceMetadata,
              !requests.isEmpty,
              Set(requests.map(\.sourceWorkspaceId)).count == requests.count,
              Set(requests.map(\.targetWorkspaceId)).count == requests.count else { throw BackupServiceError.invalidBackup }
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
            try WorkspaceBackupTransfer.validateIntegrity(in: db)
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
        var results: [WorkspaceBackupRestoreResult] = []
        for request in requests {
            do {
                let target = try combined.dbQueue.read { db in
                    try BackupService.validateRestoreRequests([request], metadata: metadata, in: db)[request.targetWorkspaceId]
                }
                if let target {
                    _ = try BackupService.createGeneration(
                        workspaceIds: [target.id], dbQueue: combined.dbQueue,
                        directoryURL: applicationSupportURL.appending(path: BackupService.backupDirectoryName),
                        reason: .beforeRestore,
                        appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                        appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
                        fileStoreDirectory: applicationSupportURL.appending(path: "FileStore")
                    )
                }
                try combined.dbQueue.write { db in
                    guard let original = try WorkspaceRecord.fetchOne(
                        db,
                        sql: "SELECT * FROM backup_source.workspaces WHERE id = ?",
                        arguments: [request.sourceWorkspaceId]
                    ) else {
                        throw BackupServiceError.invalidBackup
                    }
                    var restoredWorkspace = WorkspaceBackupTransfer.portableWorkspace(original)
                    if let target {
                        restoredWorkspace.path = target.path
                        restoredWorkspace.accountConnectionId = target.accountConnectionId
                        restoredWorkspace.localAIProvider = target.localAIProvider
                        restoredWorkspace.databricksProfile = target.databricksProfile
                        restoredWorkspace.summaryModelID = target.summaryModelID
                        restoredWorkspace.summaryReasoningEffort = target.summaryReasoningEffort
                        restoredWorkspace.chatModelID = target.chatModelID
                        restoredWorkspace.chatReasoningEffort = target.chatReasoningEffort
                    } else {
                        restoredWorkspace.id = request.targetWorkspaceId
                        restoredWorkspace.name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        restoredWorkspace.createdAt = .now
                        restoredWorkspace.lastOpenedAt = .now
                    }
                    let retainedAudio = target == nil ? [] : try WorkspaceBackupTransfer.retainedAudio(workspaceId: request.targetWorkspaceId, in: db)
                    if target != nil { try WorkspaceBackupTransfer.removeWorkspaceContent(id: request.targetWorkspaceId, in: db) }
                    try WorkspaceBackupTransfer.copy(
                        workspaceId: request.sourceWorkspaceId,
                        in: db,
                        destinationWorkspace: restoredWorkspace,
                        remapIDs: request.mode == .newWorkspace,
                        storeOriginal: { sourceId, destinationId in
                            guard let file = try FileRecord
                                .fetchOne(db, sql: "SELECT * FROM backup_source.files WHERE id = ?", arguments: [sourceId]) else {
                                throw BackupServiceError.invalidBackup
                            }
                            let bytes: Data
                            if let archiveDirectory {
                                bytes = try Data(contentsOf: archiveDirectory.appending(path: "files/\(sourceId.uuidString.lowercased())/original"))
                            } else {
                                guard let legacy = try Data.fetchOne(
                                    db,
                                    sql: "SELECT imageData FROM backup_source.file_migration_content WHERE fileId = ?",
                                    arguments: [sourceId]
                                ) else {
                                    throw BackupServiceError.invalidBackup
                                }
                                bytes = legacy
                            }
                            guard Int64(bytes.count) == file.size else { throw BackupServiceError.invalidBackup }
                            let source = ScreenshotRemoteReference(
                                origin: "",
                                accountConnectionId: nil,
                                fileId: destinationId,
                                contentHash: file.contentHash
                            )
                            let store = try ScreenshotFileStore(directory: applicationSupportURL.appending(path: "FileStore"))
                            try store.write(
                                ScreenshotContent(data: bytes, mimeType: file.contentType, variant: .original),
                                source: source,
                                required: true
                            )
                            return try source.jsonString()
                        }
                    )
                    try WorkspaceBackupTransfer.restoreRetainedAudio(retainedAudio, in: db)
                    try WorkspaceBackupTransfer.validateIntegrity(in: db)
                }
                results.append(WorkspaceBackupRestoreResult(request: request, error: nil))
            } catch {
                results.append(WorkspaceBackupRestoreResult(request: request, error: error.localizedDescription))
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
