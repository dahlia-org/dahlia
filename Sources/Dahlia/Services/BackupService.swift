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

    func preflightItems() throws -> [BackupPreflightItem] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT recording_sessions.id AS sessionId,
                       recording_sessions.meetingId,
                       meetings.name AS meetingName,
                       recording_sessions.startedAt,
                       recording_sessions.endedAt,
                       recording_sessions.batchLastAttemptAt,
                       recording_sessions.batchLastError
                FROM recording_sessions
                JOIN meetings ON meetings.id = recording_sessions.meetingId
                WHERE recording_sessions.transcriptionMode = ?
                  AND recording_sessions.batchCompletedAt IS NULL
                  AND recording_sessions.batchDiscardedAt IS NULL
                  AND (
                    EXISTS (
                        SELECT 1 FROM recording_audio_segments
                        WHERE recording_audio_segments.recordingSessionId = recording_sessions.id
                          AND recording_audio_segments.state != ?
                    )
                  )
                ORDER BY recording_sessions.startedAt ASC
                """,
                arguments: [TranscriptionMode.batch.rawValue, RecordingAudioSegmentState.purged.rawValue]
            )
            return rows.map { row in
                let endedAt: Date? = row["endedAt"]
                let attemptedAt: Date? = row["batchLastAttemptAt"]
                let failure: String? = row["batchLastError"]
                let state: BackupPreflightItem.State = if endedAt == nil {
                    .recording
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
                    meetingName: (row["meetingName"] as String).nilIfBlank ?? L10n.untitledMeeting,
                    startedAt: row["startedAt"],
                    state: state,
                    failureMessage: failure
                )
            }
        }
    }

    func createGeneration(reason: BackupMetadata.Reason = .manual) throws -> BackupGeneration {
        let unresolved = try preflightItems()
        guard unresolved.isEmpty else { throw BackupServiceError.unresolvedAudio(unresolved.count) }
        try ensureDirectory(backupDirectoryURL)

        let metadata = BackupMetadata(
            formatVersion: BackupMetadata.currentFormatVersion,
            generationId: .v7(),
            createdAt: .now,
            schemaVersion: AppDatabaseManager.currentSchemaVersion,
            migrationIdentifier: AppDatabaseManager.currentMigrationIdentifier,
            appVersion: appVersion,
            appBuild: appBuild,
            reason: reason
        )
        let destinationURL = backupDirectoryURL.appending(path: filename(for: metadata))
        let temporaryURL = backupDirectoryURL.appending(path: ".\(metadata.generationId.uuidString).tmp.sqlite")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        let destinationQueue = try DatabaseQueue(path: temporaryURL.path)
        try dbQueue.backup(to: destinationQueue)
        try destinationQueue.write { db in
            let unresolvedCount = try Self.unresolvedAudioCount(in: db)
            guard unresolvedCount == 0 else {
                throw BackupServiceError.unresolvedAudio(unresolvedCount)
            }
            try Self.sanitizeAudioReferences(in: db)
            try Self.writeMetadata(metadata, in: db)
            try Self.validateIntegrity(in: db)
        }
        try destinationQueue.close()
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        let storedMetadata = try Self.readAndValidateMetadata(at: destinationURL)
        return BackupGeneration(
            fileURL: destinationURL,
            metadata: storedMetadata,
            fileSize: Self.fileSize(at: destinationURL),
            validationError: nil
        )
    }

    func importGeneration(from sourceURL: URL) throws -> BackupGeneration {
        try ensureDirectory(backupDirectoryURL)
        let temporaryURL = backupDirectoryURL.appending(path: ".import-\(UUID.v7().uuidString).tmp.sqlite")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        let metadata = try Self.readAndValidateMetadata(at: temporaryURL)
        try ensureCompatible(metadata: metadata, at: temporaryURL)
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

    func prepareRestore(from generation: BackupGeneration) throws -> PendingDatabaseRestore {
        guard let listedMetadata = generation.metadata, generation.isValid else {
            throw BackupServiceError.invalidBackup
        }
        let unresolved = try preflightItems()
        guard unresolved.isEmpty else { throw BackupServiceError.unresolvedAudio(unresolved.count) }
        try validateManagedGenerationFile(generation.fileURL)

        let metadata = try Self.readAndValidateMetadata(at: generation.fileURL)
        guard metadata == listedMetadata else { throw BackupServiceError.invalidBackup }
        try ensureCompatible(metadata: metadata, at: generation.fileURL)
        try ensureDirectory(restoreDirectoryURL)
        let markerURL = restoreDirectoryURL.appending(path: Self.pendingRestoreFilename)
        guard !fileManager.fileExists(atPath: markerURL.path) else {
            throw BackupServiceError.restoreAlreadyPending
        }

        _ = try createGeneration(reason: .beforeRestore)
        let finalUnresolved = try preflightItems()
        guard finalUnresolved.isEmpty else {
            throw BackupServiceError.unresolvedAudio(finalUnresolved.count)
        }
        let stagedFilename = "staged-\(UUID.v7().uuidString).sqlite"
        let stagedURL = restoreDirectoryURL.appending(path: stagedFilename)
        do {
            try fileManager.copyItem(at: generation.fileURL, to: stagedURL)
            let stagedMetadata = try Self.readAndValidateMetadata(at: stagedURL)
            guard stagedMetadata == metadata else { throw BackupServiceError.invalidBackup }
            try ensureCompatible(metadata: stagedMetadata, at: stagedURL)
            let stagedDatabase = try AppDatabaseManager(path: stagedURL.path)
            try stagedDatabase.dbQueue.write { db in
                guard try AppDatabaseManager.hasExpectedCurrentSchema(
                    db,
                    excludingTableNames: [Self.metadataTableName]
                ) else {
                    throw BackupServiceError.invalidBackup
                }
                try Self.sanitizeAudioReferences(in: db)
                try db.execute(sql: "DROP TABLE IF EXISTS \(Self.metadataTableName)")
                guard try AppDatabaseManager.hasExpectedCurrentSchema(db) else {
                    throw BackupServiceError.invalidBackup
                }
                try Self.validateIntegrity(in: db)
            }
            try stagedDatabase.dbQueue.close()
            let checksum = try Self.sha256(of: stagedURL)
            let marker = PendingDatabaseRestore(
                stagedFilename: stagedFilename,
                sha256: checksum,
                requestedAt: .now,
                sourceMetadata: metadata
            )
            let data = try JSONEncoder.backupEncoder.encode(marker)
            try data.write(to: markerURL, options: [.atomic])
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
        return try queue.read { db in
            if shouldValidateIntegrity {
                try validateIntegrity(in: db)
            }
            guard try db.tableExists(metadataTableName),
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM \(metadataTableName) LIMIT 1") else {
                throw BackupServiceError.invalidBackup
            }
            let generationIdString: String = row["generationId"]
            guard let generationId = UUID(uuidString: generationIdString),
                  let reason = BackupMetadata.Reason(rawValue: row["reason"]) else {
                throw BackupServiceError.invalidBackup
            }
            let metadata = BackupMetadata(
                formatVersion: row["formatVersion"],
                generationId: generationId,
                createdAt: row["createdAt"],
                schemaVersion: row["schemaVersion"],
                migrationIdentifier: row["migrationIdentifier"],
                appVersion: row["appVersion"],
                appBuild: row["appBuild"],
                reason: reason
            )
            guard metadata.formatVersion == BackupMetadata.currentFormatVersion else {
                throw BackupServiceError.incompatibleFormat(metadata.formatVersion)
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

    private func ensureCompatible(metadata: BackupMetadata, at url: URL) throws {
        guard metadata.formatVersion == BackupMetadata.currentFormatVersion else {
            throw BackupServiceError.incompatibleFormat(metadata.formatVersion)
        }
        guard let index = AppDatabaseManager.migrationIdentifiers.firstIndex(of: metadata.migrationIdentifier) else {
            throw BackupServiceError.newerSchema(metadata.migrationIdentifier)
        }
        let expectedVersion = AppDatabaseManager.schemaVersion(from: metadata.migrationIdentifier)
        guard expectedVersion == metadata.schemaVersion else { throw BackupServiceError.invalidBackup }

        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try queue.read { db in
            let completed = try AppDatabaseManager.migrator.completedMigrations(db)
            let expected = Array(AppDatabaseManager.migrationIdentifiers.prefix(index + 1))
            guard completed == expected,
                  try !AppDatabaseManager.migrator.hasBeenSuperseded(db) else {
                throw BackupServiceError.newerSchema(metadata.migrationIdentifier)
            }
        }
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
        }
        try db.execute(
            sql: """
            INSERT INTO \(metadataTableName)
                (formatVersion, generationId, createdAt, schemaVersion, migrationIdentifier, appVersion, appBuild, reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
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
            ]
        )
    }

    private nonisolated static func sanitizeAudioReferences(in db: Database) throws {
        for table in [
            "recording_audio_ranges",
            "recording_audio_files",
            "recording_audio_reconciliation_issues",
            "recording_audio_segment_ranges",
            "recording_audio_source_progress",
            "recording_audio_segments",
        ] where try db.tableExists(table) {
            try db.execute(sql: "DELETE FROM \(table)")
        }
        if try db.tableExists("recording_sessions") {
            try db.execute(
                sql: """
                UPDATE recording_sessions
                SET retainAudioAfterBatch = 0,
                    audioRetentionPolicy = NULL,
                    retentionExpiresAt = NULL
                """
            )
        }
    }

    private nonisolated static func unresolvedAudioCount(in db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*)
            FROM recording_sessions
            WHERE transcriptionMode = ?
              AND batchCompletedAt IS NULL
              AND batchDiscardedAt IS NULL
              AND EXISTS (
                  SELECT 1 FROM recording_audio_segments
                  WHERE recording_audio_segments.recordingSessionId = recording_sessions.id
                    AND recording_audio_segments.state != ?
              )
            """,
            arguments: [TranscriptionMode.batch.rawValue, RecordingAudioSegmentState.purged.rawValue]
        ) ?? 0
    }

    private nonisolated static func validateIntegrity(in db: Database) throws {
        let quickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "unknown"
        guard quickCheck == "ok" else { throw BackupServiceError.integrityCheckFailed(quickCheck) }
        let foreignKeyFailures = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        guard foreignKeyFailures.isEmpty else {
            throw BackupServiceError.integrityCheckFailed("foreign key check failed")
        }
    }

    private nonisolated static func fileSize(at url: URL) -> Int64 {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(size ?? 0)
    }
}

private extension JSONEncoder {
    static var backupEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var backupDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
