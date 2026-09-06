import CryptoKit
import DahliaRuntimeSupport
import Foundation
import GRDB

enum BackupServiceError: LocalizedError, Equatable {
    case unresolvedAudio(Int)
    case invalidBackup
    case incompatibleFormat(Int)
    case newerSchema(String)
    case integrityCheckFailed(String)
    case restoreAlreadyPending
    case restoreTargetUnavailable
    case generationNotFound

    var errorDescription: String? {
        switch self {
        case let .unresolvedAudio(count):
            L10n.resolveUnprocessedRecordings(count)
        case .invalidBackup:
            L10n.selectedBackupInvalid
        case let .incompatibleFormat(version):
            L10n.backupFormatUnsupported(version)
        case let .newerSchema(identifier):
            L10n.backupSchemaNewer(identifier)
        case let .integrityCheckFailed(message):
            L10n.backupIntegrityCheckFailed(message)
        case .restoreAlreadyPending:
            L10n.backupRestoreAlreadyPending
        case .restoreTargetUnavailable:
            L10n.backupRestoreTargetUnavailable
        case .generationNotFound:
            L10n.backupGenerationMissing
        }
    }
}

struct PendingDatabaseRestore: Codable, Equatable, Sendable {
    let stagedFilename: String
    let sha256: String
    let requestedAt: Date
    let sourceMetadata: BackupMetadata
    let request: VaultBackupRestoreRequest
}

// Backup operations intentionally share one serialized filesystem/database owner.
// swiftlint:disable:next type_body_length
actor BackupService {
    static let metadataTableName = "dahlia_backup_metadata"
    static let backupDirectoryName = "Backups"
    static let restoreDirectoryName = "Restore"
    static let pendingRestoreFilename = "pending-restore.json"

    private let dbQueue: DatabaseQueue
    private let backupDirectoryURL: URL
    private let restoreDirectoryURL: URL
    private let fileManager: FileManager
    private let appVersion: String
    private let appBuild: String

    init(
        dbQueue: DatabaseQueue,
        applicationSupportURL: URL = DahliaApplicationSupport.currentDirectoryURL,
        fileManager: FileManager = .default,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
        appBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
    ) {
        self.dbQueue = dbQueue
        backupDirectoryURL = applicationSupportURL.appending(path: Self.backupDirectoryName, directoryHint: .isDirectory)
        restoreDirectoryURL = applicationSupportURL.appending(path: Self.restoreDirectoryName, directoryHint: .isDirectory)
        self.fileManager = fileManager
        self.appVersion = appVersion
        self.appBuild = appBuild
    }

    func listGenerations() throws -> [BackupGeneration] {
        try ensureDirectory(backupDirectoryURL)
        return try fileManager.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "sqlite" }
        .compactMap { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return nil }
            do {
                let metadata = try Self.readMetadata(at: url, validateIntegrity: false)
                return BackupGeneration(
                    fileURL: url,
                    metadata: metadata,
                    fileSize: Int64(values?.fileSize ?? 0),
                    validationError: nil
                )
            } catch {
                return BackupGeneration(
                    fileURL: url,
                    metadata: nil,
                    fileSize: Int64(values?.fileSize ?? 0),
                    validationError: error.localizedDescription
                )
            }
        }
        .sorted { lhs, rhs in
            (lhs.metadata?.createdAt ?? .distantPast) > (rhs.metadata?.createdAt ?? .distantPast)
        }
    }

    func preflightItems(vaultId: UUID? = nil) throws -> [BackupPreflightItem] {
        try dbQueue.read { db in
            var sql = """
            SELECT recording_sessions.id AS sessionId,
                   recording_sessions.meetingId,
                   meetings.vaultId,
                   meetings.name AS meetingName,
                   recording_sessions.startedAt,
                   recording_sessions.endedAt,
                   recording_sessions.batchLastAttemptAt,
                   recording_sessions.batchLastError,
                   recording_sessions.batchFailureKind,
                   NOT EXISTS (
                       SELECT 1 FROM recording_audio_segments AS candidate
                       WHERE candidate.recordingSessionId = recording_sessions.id
                         AND (
                             candidate.state != ?
                             OR candidate.purgedAt IS NOT NULL
                             OR NOT EXISTS (
                                 SELECT 1 FROM recording_audio_segment_ranges AS candidateRanges
                                 WHERE candidateRanges.audioSegmentId = candidate.id
                             )
                         )
                   ) AS hasCompleteAudio
            FROM recording_sessions
            JOIN meetings ON meetings.id = recording_sessions.meetingId
            WHERE recording_sessions.transcriptionMode = ?
              AND recording_sessions.batchCompletedAt IS NULL
              AND recording_sessions.batchDiscardedAt IS NULL
              AND EXISTS (
                  SELECT 1 FROM recording_audio_segments
                  WHERE recording_audio_segments.recordingSessionId = recording_sessions.id
                    AND recording_audio_segments.state != ?
              )
            """
            var arguments: StatementArguments = [
                RecordingAudioSegmentState.ready.rawValue,
                TranscriptionMode.batch.rawValue,
                RecordingAudioSegmentState.purged.rawValue,
            ]
            if let vaultId {
                sql += " AND meetings.vaultId = ?"
                arguments += [vaultId]
            }
            sql += " ORDER BY recording_sessions.startedAt ASC"
            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: arguments
            )
            return rows.map { row in
                let endedAt: Date? = row["endedAt"]
                let attemptedAt: Date? = row["batchLastAttemptAt"]
                let failure: String? = row["batchLastError"]
                let failureKind: BatchFailureKind? = row["batchFailureKind"]
                let hasCompleteAudio: Bool = row["hasCompleteAudio"]
                let state: BackupPreflightItem.State = if endedAt == nil {
                    .recording
                } else if failureKind == .transcriptionInterrupted {
                    .interrupted
                } else if failure?.nilIfBlank != nil {
                    .failed
                } else if attemptedAt == nil {
                    .awaitingConfirmation
                } else {
                    .processing
                }
                return BackupPreflightItem(
                    sessionId: row["sessionId"],
                    meetingId: row["meetingId"],
                    vaultId: row["vaultId"],
                    meetingName: (row["meetingName"] as String).nilIfBlank ?? L10n.untitledMeeting,
                    startedAt: row["startedAt"],
                    state: state,
                    failureMessage: failure,
                    canTranscribe: hasCompleteAudio
                        && failureKind != .recordingRecovery
                        && failureKind != .recordingAudioPermanent
                )
            }
        }
    }

    func hasProcessingAudio() throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM recording_sessions
                WHERE transcriptionMode = ? AND batchDiscardedAt IS NULL
                  AND batchLastAttemptAt IS NOT NULL AND batchLastError IS NULL AND batchFailureKind IS NULL
                  AND (batchCompletedAt IS NULL OR batchLastAttemptAt > batchCompletedAt)
                  AND EXISTS (
                    SELECT 1 FROM recording_audio_segments
                    WHERE recordingSessionId = recording_sessions.id AND state != ?
                  )
            )
            """, arguments: [TranscriptionMode.batch.rawValue, RecordingAudioSegmentState.purged.rawValue]) ?? false
        }
    }

    func listVaults() throws -> [VaultRecord] {
        try dbQueue.read { try VaultRecord.order(Column("name")).fetchAll($0) }
    }

    func createGeneration(vaultId: UUID, reason: BackupMetadata.Reason = .manual) throws -> BackupGeneration {
        try Self.createGeneration(
            vaultId: vaultId,
            dbQueue: dbQueue,
            directoryURL: backupDirectoryURL,
            reason: reason,
            appVersion: appVersion,
            appBuild: appBuild
        )
    }

    nonisolated static func createGeneration(
        vaultId: UUID,
        dbQueue: DatabaseQueue,
        directoryURL: URL,
        reason: BackupMetadata.Reason,
        appVersion: String,
        appBuild: String
    ) throws -> BackupGeneration {
        let manager = FileManager.default
        try ensureDirectory(directoryURL, fileManager: manager)
        let generationID = UUID.v7()
        let temporaryURL = directoryURL.appending(path: ".\(generationID).tmp.sqlite")
        defer { try? manager.removeItem(at: temporaryURL) }
        let snapshotURL = directoryURL.appending(path: ".\(generationID).source.sqlite")
        defer { try? manager.removeItem(at: snapshotURL) }
        let snapshot = try DatabaseQueue(path: snapshotURL.path, configuration: AppDatabaseManager.configuration())
        defer { try? snapshot.close() }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
        try dbQueue.backup(to: snapshot)
        try snapshot.writeWithoutTransaction { db in
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE")
        }
        try snapshot.close()
        let destination = try AppDatabaseManager(path: temporaryURL.path)
        defer { try? destination.close() }
        try destination.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS backup_source", arguments: [snapshotURL.path])
        }
        let metadata = try destination.dbQueue.write { db in
            guard let vault = try VaultRecord.fetchOne(db, sql: "SELECT * FROM backup_source.vaults WHERE id = ?", arguments: [vaultId]) else {
                throw BackupServiceError.invalidBackup
            }
            let unresolved = try Self.unresolvedAudioCount(in: db, vaultId: vaultId, schema: "backup_source.")
            guard unresolved == 0 else { throw BackupServiceError.unresolvedAudio(unresolved) }
            let metadata = BackupMetadata(
                formatVersion: BackupMetadata.currentFormatVersion, generationId: generationID, createdAt: .now,
                schemaVersion: AppDatabaseManager.currentSchemaVersion,
                migrationIdentifier: AppDatabaseManager.currentMigrationIdentifier,
                appVersion: appVersion, appBuild: appBuild, reason: reason, vaultId: vault.id, vaultName: vault.name
            )
            try VaultBackupTransfer.copy(
                vaultId: vaultId,
                in: db,
                destinationVault: VaultBackupTransfer.portableVault(vault),
                remapIDs: false
            )
            try clearSearchIndex(in: db)
            try writeMetadata(metadata, in: db)
            try VaultBackupTransfer.validateIntegrity(in: db)
            return metadata
        }
        try destination.close()
        let url = directoryURL.appending(path: "Dahlia-\(metadata.generationId).sqlite")
        try manager.moveItem(at: temporaryURL, to: url)
        return try BackupGeneration(fileURL: url, metadata: readAndValidateMetadata(at: url), fileSize: fileSize(at: url), validationError: nil)
    }

    private nonisolated static func clearSearchIndex(in db: Database) throws {
        try db.execute(sql: "DELETE FROM search_documents_fts; DELETE FROM search_documents; DELETE FROM search_index_jobs")
        try db.execute(sql: "UPDATE search_index_state SET phase = 'pending', totalCount = 0, completedCount = 0")
    }

    func importGeneration(from sourceURL: URL) throws -> BackupGeneration {
        try ensureDirectory(backupDirectoryURL)
        let temporaryURL = backupDirectoryURL.appending(path: ".import-\(UUID.v7().uuidString).tmp.sqlite")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        let metadata = try Self.readAndValidateMetadata(at: temporaryURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        let importedURL = backupDirectoryURL.appending(
            path: "Imported-\(filename(for: metadata, uniqueSuffix: UUID.v7().uuidString))"
        )
        try fileManager.moveItem(at: temporaryURL, to: importedURL)
        return BackupGeneration(
            fileURL: importedURL,
            metadata: metadata,
            fileSize: Self.fileSize(at: importedURL),
            validationError: nil
        )
    }

    func exportGeneration(_ generation: BackupGeneration, to destinationURL: URL) throws {
        try validateManagedGenerationFile(generation.fileURL)
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appending(path: ".dahlia-export-\(UUID.v7().uuidString).sqlite")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.copyItem(at: generation.fileURL, to: temporaryURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    func deleteGeneration(_ generation: BackupGeneration) throws {
        try validateManagedGenerationFile(generation.fileURL)
        try fileManager.removeItem(at: generation.fileURL)
    }

    func prepareRestore(
        from generation: BackupGeneration, request: VaultBackupRestoreRequest
    ) throws -> PendingDatabaseRestore {
        guard let listedMetadata = generation.metadata, generation.isValid,
              request.sourceVaultId == listedMetadata.vaultId,
              request.name.nilIfBlank != nil,
              request.mode != .overwrite || request.targetVaultId == request.sourceVaultId else {
            throw BackupServiceError.invalidBackup
        }
        try validateManagedGenerationFile(generation.fileURL)
        let metadata = try Self.readAndValidateMetadata(at: generation.fileURL)
        guard metadata == listedMetadata else { throw BackupServiceError.invalidBackup }
        if request.mode == .overwrite {
            _ = try dbQueue.read { try VaultBackupTransfer.validateLocalTarget(id: request.targetVaultId, in: $0) }
            let unresolved = try preflightItems(vaultId: request.targetVaultId)
            guard unresolved.isEmpty else { throw BackupServiceError.unresolvedAudio(unresolved.count) }
        }
        guard try !preflightItems().contains(where: \.isWorkInProgress), try !hasProcessingAudio() else {
            throw BackupServiceError.unresolvedAudio(1)
        }
        try ensureDirectory(restoreDirectoryURL)
        let markerURL = restoreDirectoryURL.appending(path: Self.pendingRestoreFilename)
        guard !fileManager.fileExists(atPath: markerURL.path) else { throw BackupServiceError.restoreAlreadyPending }
        let stagedFilename = "staged-\(UUID.v7()).sqlite"
        let stagedURL = restoreDirectoryURL.appending(path: stagedFilename)
        do {
            try fileManager.copyItem(at: generation.fileURL, to: stagedURL)
            guard try Self.readAndValidateMetadata(at: stagedURL) == metadata else { throw BackupServiceError.invalidBackup }
            let marker = try PendingDatabaseRestore(
                stagedFilename: stagedFilename, sha256: Self.sha256(of: stagedURL), requestedAt: .now,
                sourceMetadata: metadata, request: request
            )
            try JSONEncoder.backupEncoder.encode(marker).write(to: markerURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
            return marker
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }
    }

    nonisolated static func pendingRestoreURL(
        applicationSupportURL: URL = DahliaApplicationSupport.currentDirectoryURL
    ) -> URL {
        applicationSupportURL
            .appending(path: restoreDirectoryName, directoryHint: .isDirectory)
            .appending(path: pendingRestoreFilename)
    }

    nonisolated static func readAndValidateMetadata(at url: URL) throws -> BackupMetadata {
        try readMetadata(at: url, validateIntegrity: true)
    }

    private nonisolated static func readMetadata(
        at url: URL,
        validateIntegrity shouldValidateIntegrity: Bool
    ) throws -> BackupMetadata {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            if shouldValidateIntegrity {
                try VaultBackupTransfer.validateIntegrity(in: db)
            }
            guard try db.tableExists(metadataTableName),
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(metadataTableName)") == 1,
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM \(metadataTableName) LIMIT 1") else {
                throw BackupServiceError.invalidBackup
            }
            let format: Int = try row.decode(forColumn: "formatVersion")
            guard format == BackupMetadata.currentFormatVersion else { throw BackupServiceError.incompatibleFormat(format) }
            guard let vaultID = try UUID(uuidString: row.decode(String.self, forColumn: "vaultId")),
                  let generationID = try UUID(uuidString: row.decode(String.self, forColumn: "generationId")),
                  let reason = try BackupMetadata.Reason(rawValue: row.decode(String.self, forColumn: "reason")) else {
                throw BackupServiceError.invalidBackup
            }
            let metadata = try BackupMetadata(
                formatVersion: format,
                generationId: generationID,
                createdAt: row.decode(forColumn: "createdAt"),
                schemaVersion: row.decode(forColumn: "schemaVersion"),
                migrationIdentifier: row.decode(forColumn: "migrationIdentifier"),
                appVersion: row.decode(forColumn: "appVersion"),
                appBuild: row.decode(forColumn: "appBuild"),
                reason: reason, vaultId: vaultID, vaultName: row.decode(forColumn: "vaultName")
            )
            if shouldValidateIntegrity {
                guard let index = AppDatabaseManager.migrationIdentifiers.firstIndex(of: metadata.migrationIdentifier),
                      metadata.schemaVersion == AppDatabaseManager.schemaVersion(from: metadata.migrationIdentifier) else {
                    throw BackupServiceError.newerSchema(metadata.migrationIdentifier)
                }
                guard try AppDatabaseManager.migrator.completedMigrations(db) == Array(AppDatabaseManager.migrationIdentifiers.prefix(index + 1)),
                      try !AppDatabaseManager.migrator.hasBeenSuperseded(db),
                      try AppDatabaseManager.hasExpectedSchema(db, upTo: metadata.migrationIdentifier, excludingTableNames: [metadataTableName]),
                      try VaultRecord.fetchCount(db) == 1,
                      try String.fetchOne(db, sql: "SELECT name FROM vaults WHERE id = ?", arguments: [metadata.vaultId])
                      == metadata.vaultName else { throw BackupServiceError.invalidBackup }
            }
            return metadata
        }
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func filename(for metadata: BackupMetadata, uniqueSuffix: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = uniqueSuffix ?? metadata.generationId.uuidString
        return "Dahlia-Backup-\(formatter.string(from: metadata.createdAt))-schema-v\(metadata.schemaVersion)-\(suffix).sqlite"
    }

    private func ensureDirectory(_ url: URL) throws {
        try Self.ensureDirectory(url, fileManager: fileManager)
    }

    private nonisolated static func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw BackupServiceError.invalidBackup
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func validateManagedGenerationFile(_ url: URL) throws {
        let standardizedDirectory = backupDirectoryURL.standardizedFileURL
        guard url.deletingLastPathComponent().standardizedFileURL == standardizedDirectory else {
            throw BackupServiceError.generationNotFound
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              url.resolvingSymlinksInPath().deletingLastPathComponent()
              == standardizedDirectory.resolvingSymlinksInPath() else {
            throw BackupServiceError.generationNotFound
        }
    }

    private nonisolated static func writeMetadata(_ metadata: BackupMetadata, in db: Database) throws {
        try db.execute(sql: "DROP TABLE IF EXISTS \(metadataTableName)")
        try db.create(table: metadataTableName) { table in
            table.column("formatVersion", .integer).notNull()
            table.column("generationId", .text).notNull()
            table.column("createdAt", .datetime).notNull()
            table.column("schemaVersion", .integer).notNull()
            table.column("migrationIdentifier", .text).notNull()
            table.column("appVersion", .text).notNull()
            table.column("appBuild", .text).notNull()
            table.column("reason", .text).notNull()
            table.column("vaultId", .text).notNull()
            table.column("vaultName", .text).notNull()
        }
        try db.execute(
            sql: """
            INSERT INTO \(metadataTableName)
                (formatVersion, generationId, createdAt, schemaVersion, migrationIdentifier, appVersion, appBuild, reason, vaultId, vaultName)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                metadata.formatVersion,
                metadata.generationId.uuidString,
                metadata.createdAt,
                metadata.schemaVersion,
                metadata.migrationIdentifier,
                metadata.appVersion,
                metadata.appBuild,
                metadata.reason.rawValue,
                metadata.vaultId.uuidString,
                metadata.vaultName,
            ]
        )
    }

    nonisolated static func unresolvedAudioCount(in db: Database, vaultId: UUID, schema: String = "") throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM \(schema)recording_sessions
            WHERE meetingId IN (SELECT id FROM \(schema)meetings WHERE vaultId = ?)
              AND transcriptionMode = ?
              AND batchCompletedAt IS NULL
              AND batchDiscardedAt IS NULL
              AND EXISTS (
                  SELECT 1 FROM \(schema)recording_audio_segments
                  WHERE recording_audio_segments.recordingSessionId = recording_sessions.id
                    AND recording_audio_segments.state != ?
              )
            """,
            arguments: [vaultId, TranscriptionMode.batch.rawValue, RecordingAudioSegmentState.purged.rawValue]
        ) ?? 0
    }

    private nonisolated static func fileSize(at url: URL) -> Int64 {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(size ?? 0)
    }
}

private extension JSONEncoder {
    static var backupEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }
}

extension JSONDecoder {
    static var backupDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}
