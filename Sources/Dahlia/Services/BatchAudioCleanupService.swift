import Foundation
import GRDB

/// 旧形式の音声参照が残る親レコードを削除する前に、対象ファイルを安全に除去する。
enum BatchAudioCleanupService {
    struct DeletionTarget {
        let baseURL: URL
        let relativePath: String
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
                let vaultURL = URL(fileURLWithPath: row["vaultPath"])
                return DeletionTarget(
                    baseURL: BatchAudioStorage.baseURL(for: location, vaultURL: vaultURL),
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
}
