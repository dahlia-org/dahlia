import Foundation
import GRDB

/// 旧形式の音声参照が残る親レコードを削除する前に、対象ファイルを安全に除去する。
enum BatchAudioCleanupService {
    struct DeletionTarget {
        let baseURL: URL
        let relativePath: String
    }

    struct StagedFile {
        let originalURL: URL
        let stagedURL: URL
    }

    static func deletionTargets(
        meetingIds: Set<UUID>,
        dbQueue: DatabaseQueue,
        includeVaultAudio: Bool = true
    ) throws -> [DeletionTarget] {
        guard !meetingIds.isEmpty else { return [] }
        return try dbQueue.read { db in
            var arguments = StatementArguments(meetingIds)
            let storageCondition: String
            if includeVaultAudio {
                storageCondition = ""
            } else {
                storageCondition = "AND recording_audio_files.storageLocation = ?"
                arguments += [RecordingAudioStorageLocation.managed.rawValue]
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT vaults.path AS vaultPath,
                       recording_audio_files.storageLocation AS storageLocation,
                       recording_audio_files.relativePath AS relativePath
                FROM recording_audio_files
                JOIN recording_sessions ON recording_sessions.id = recording_audio_files.recordingSessionId
                JOIN meetings ON meetings.id = recording_sessions.meetingId
                JOIN vaults ON vaults.id = meetings.vaultId
                WHERE meetings.id IN (\(meetingIds.map { _ in "?" }.joined(separator: ",")))
                \(storageCondition)
                """,
                arguments: arguments
            )
            return rows.compactMap { row in
                guard let location = RecordingAudioStorageLocation(rawValue: row["storageLocation"]) else { return nil }
                let baseURL: URL
                switch location {
                case .managed:
                    baseURL = BatchAudioStorage.managedRootURL
                case .vault:
                    guard let vaultPath: String = row["vaultPath"] else { return nil }
                    baseURL = URL(fileURLWithPath: vaultPath)
                }
                return DeletionTarget(
                    baseURL: baseURL,
                    relativePath: row["relativePath"]
                )
            }
        }
    }

    static func deletionTargets(
        vaultId: UUID,
        dbQueue: DatabaseQueue
    ) throws -> [DeletionTarget] {
        let meetingIds = try dbQueue.read { db in
            try UUID.fetchAll(
                db,
                sql: "SELECT id FROM meetings WHERE vaultId = ?",
                arguments: [vaultId]
            )
        }
        // Vault登録解除ではユーザーが明示的に保持したVault内ファイルを削除しない。
        return try deletionTargets(
            meetingIds: Set(meetingIds),
            dbQueue: dbQueue,
            includeVaultAudio: false
        )
    }

    static func deleteFiles(_ targets: [DeletionTarget]) throws {
        for target in targets {
            try BatchAudioStorage.removeFilesChecked(
                baseURL: target.baseURL,
                relativePaths: [target.relativePath]
            )
        }
    }

    static func stageFiles(_ targets: [DeletionTarget]) throws -> [StagedFile] {
        var stagedFiles: [StagedFile] = []
        var seenPaths: Set<String> = []
        do {
            for target in targets {
                guard let finalURL = BatchAudioStorage.safeURL(
                    baseURL: target.baseURL,
                    relativePath: target.relativePath
                ) else {
                    throw RecordingAudioStoreError.invalidPath
                }
                let partialURL = finalURL.deletingPathExtension().appendingPathExtension("partial.caf")
                for originalURL in [finalURL, partialURL]
                    where seenPaths.insert(originalURL.standardizedFileURL.path).inserted
                    && FileManager.default.fileExists(atPath: originalURL.path) {
                    let stagedURL = originalURL.deletingLastPathComponent()
                        .appending(path: ".dahlia-delete-\(UUID().uuidString)-\(originalURL.lastPathComponent)")
                    try FileManager.default.moveItem(at: originalURL, to: stagedURL)
                    stagedFiles.append(StagedFile(originalURL: originalURL, stagedURL: stagedURL))
                }
            }
            return stagedFiles
        } catch let operationError {
            do {
                try restoreStagedFiles(stagedFiles)
            } catch let rollbackError {
                throw ProjectWorkspaceError.rollbackFailed(
                    operation: operationError.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw operationError
        }
    }

    static func restoreStagedFiles(_ stagedFiles: [StagedFile]) throws {
        try restoreStagedFiles(
            stagedFiles,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) }
        )
    }

    static func restoreStagedFiles(
        _ stagedFiles: [StagedFile],
        fileExists: (URL) -> Bool,
        moveItem: (URL, URL) throws -> Void
    ) throws {
        var firstError: (any Error)?
        for stagedFile in stagedFiles.reversed() {
            guard fileExists(stagedFile.stagedURL) else { continue }
            do {
                try moveItem(stagedFile.stagedURL, stagedFile.originalURL)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    static func discardStagedFiles(
        _ stagedFiles: [StagedFile],
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        var firstError: (any Error)?
        for stagedFile in stagedFiles {
            do {
                try removeItem(stagedFile.stagedURL)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }
}
