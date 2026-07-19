import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BackupServiceTests {
        @Test
        // swiftlint:disable:next function_body_length
        func generationEmbedsSchemaAndRemovesAudioReferences() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "BackupSanitization",
                meetingStatus: .ready,
                endedAt: Date(timeIntervalSince1970: 1_776_384_060),
                duration: 60,
                retainAudioAfterBatch: true,
                batchCompletedAt: Date(timeIntervalSince1970: 1_776_384_070)
            )
            defer { fixture.removeFiles() }
            let segment = makeAudioSegment(fixture: fixture)
            let transcript = TranscriptSegmentRecord(
                id: .v7(),
                meetingId: fixture.meeting.id,
                sessionId: fixture.session.id,
                startTime: fixture.now,
                endTime: fixture.now.addingTimeInterval(1),
                text: "Preserved transcript",
                translatedText: nil,
                isConfirmed: true,
                speakerLabel: "mic"
            )
            try await fixture.database.dbQueue.write { db in
                try segment.insert(db)
                try RecordingAudioSegmentRangeRecord(
                    id: .v7(),
                    audioSegmentId: segment.id,
                    startFrame: 0,
                    frameCount: 160,
                    sessionOffsetSeconds: 0,
                    localeIdentifier: "ja_JP",
                    createdAt: fixture.now,
                    updatedAt: fixture.now
                ).insert(db)
                try RecordingAudioSourceProgressRecord(
                    recordingSessionId: fixture.session.id,
                    source: .microphone,
                    isRequired: true,
                    captureState: .ended,
                    durableThroughOffsetSeconds: 1,
                    lastContiguousReadySegmentIndex: 0,
                    failureCode: nil,
                    createdAt: fixture.now,
                    updatedAt: fixture.now
                ).insert(db)
                try RecordingAudioReconciliationIssueRecord(
                    id: .v7(),
                    recordingSessionId: fixture.session.id,
                    audioSegmentId: segment.id,
                    relativePath: segment.finalRelativePath,
                    reason: "test",
                    firstObservedAt: fixture.now,
                    lastObservedAt: fixture.now,
                    resolvedAt: nil
                ).insert(db)
                try transcript.insert(db)
            }

            let service = BackupService(
                dbQueue: fixture.database.dbQueue,
                applicationSupportURL: fixture.testRootURL,
                appVersion: "1.2.3",
                appBuild: "45"
            )
            let generation = try await service.createGeneration()
            let metadata = try #require(generation.metadata)
            #expect(metadata.schemaVersion == AppDatabaseManager.currentSchemaVersion)
            #expect(metadata.migrationIdentifier == AppDatabaseManager.currentMigrationIdentifier)
            #expect(metadata.appVersion == "1.2.3")
            #expect(metadata.appBuild == "45")

            var configuration = Configuration()
            configuration.readonly = true
            let backup = try DatabaseQueue(path: generation.fileURL.path, configuration: configuration)
            let result = try await backup.read { db in
                let transcriptText = try String.fetchOne(
                    db,
                    sql: "SELECT text FROM transcript_segments WHERE id = ?",
                    arguments: [transcript.id]
                )
                let session = try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)
                return try (
                    transcriptText,
                    #require(session),
                    RecordingAudioSegmentRecord.fetchCount(db),
                    RecordingAudioSegmentRangeRecord.fetchCount(db),
                    RecordingAudioSourceProgressRecord.fetchCount(db),
                    RecordingAudioReconciliationIssueRecord.fetchCount(db)
                )
            }
            #expect(result.0 == "Preserved transcript")
            #expect(!result.1.retainAudioAfterBatch)
            #expect(result.1.audioRetentionPolicy == nil)
            #expect(result.2 == 0)
            #expect(result.3 == 0)
            #expect(result.4 == 0)
            #expect(result.5 == 0)
        }

        @Test
        func unresolvedAudioBlocksGenerationAndAppearsInPreflight() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "BackupPreflight",
                endedAt: Date(timeIntervalSince1970: 1_776_384_060),
                duration: 60
            )
            defer { fixture.removeFiles() }
            let segment = makeAudioSegment(fixture: fixture)
            try await fixture.database.dbQueue.write { db in
                try segment.insert(db)
            }
            let service = BackupService(
                dbQueue: fixture.database.dbQueue,
                applicationSupportURL: fixture.testRootURL
            )

            let items = try await service.preflightItems()
            #expect(items.count == 1)
            #expect(items.first?.state == .awaitingConfirmation)
            await #expect(throws: BackupServiceError.unresolvedAudio(1)) {
                try await service.createGeneration()
            }
        }

        @Test
        func legacyAudioReferencesAreIgnoredAndRemovedFromBackup() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "BackupLegacyAudio",
                endedAt: Date(timeIntervalSince1970: 1_776_384_060),
                duration: 60
            )
            defer { fixture.removeFiles() }
            try await fixture.database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO recording_audio_files
                        (id, recordingSessionId, source, relativePath, sampleRate, channelCount,
                         finalizedAt, totalFrameCount, createdAt, updatedAt, storageLocation)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID.v7(), fixture.session.id, RecordingAudioSource.microphone.rawValue,
                        "legacy/microphone.caf", 16_000, 1, fixture.now, 160,
                        fixture.now, fixture.now, RecordingAudioStorageLocation.vault.rawValue,
                    ]
                )
            }
            let service = BackupService(
                dbQueue: fixture.database.dbQueue,
                applicationSupportURL: fixture.testRootURL
            )

            #expect(try await service.preflightItems().isEmpty)
            let generation = try await service.createGeneration()
            let backup = try DatabaseQueue(path: generation.fileURL.path)
            let legacyCount = try await backup.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recording_audio_files")
            }
            #expect(legacyCount == 0)
        }

        @Test
        func restorePreparationCreatesSafetyGenerationAndSanitizedStagingDatabase() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "BackupRestorePreparation",
                meetingStatus: .ready,
                endedAt: Date(timeIntervalSince1970: 1_776_384_060),
                duration: 60,
                batchCompletedAt: Date(timeIntervalSince1970: 1_776_384_070)
            )
            defer { fixture.removeFiles() }
            let service = BackupService(
                dbQueue: fixture.database.dbQueue,
                applicationSupportURL: fixture.testRootURL,
                appVersion: "1.2.3",
                appBuild: "45"
            )
            let generation = try await service.createGeneration()

            let marker = try await service.prepareRestore(from: generation)
            let generations = try await service.listGenerations()
            #expect(generations.count == 2)
            #expect(generations.contains { $0.metadata?.reason == .beforeRestore })

            let stagedURL = fixture.testRootURL
                .appending(path: BackupService.restoreDirectoryName)
                .appending(path: marker.stagedFilename)
            #expect(try BackupService.sha256(of: stagedURL) == marker.sha256)
            var configuration = Configuration()
            configuration.readonly = true
            let staged = try DatabaseQueue(path: stagedURL.path, configuration: configuration)
            let isClean = try await staged.read { db in
                let hasMetadata = try db.tableExists(BackupService.metadataTableName)
                let migrationsComplete = try AppDatabaseManager.migrator.hasCompletedMigrations(db)
                let audioCount = try RecordingAudioSegmentRecord.fetchCount(db)
                return !hasMetadata && migrationsComplete && audioCount == 0
            }
            #expect(isClean)
        }

        @Test
        func importRejectsBackupWhoseMetadataClaimsUnknownSchema() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "BackupFutureSchema",
                endedAt: Date(timeIntervalSince1970: 1_776_384_060),
                duration: 60,
                batchCompletedAt: Date(timeIntervalSince1970: 1_776_384_070)
            )
            defer { fixture.removeFiles() }
            let service = BackupService(
                dbQueue: fixture.database.dbQueue,
                applicationSupportURL: fixture.testRootURL
            )
            let generation = try await service.createGeneration()
            let editedURL = fixture.testRootURL.appending(path: "future.sqlite")
            try FileManager.default.copyItem(at: generation.fileURL, to: editedURL)
            let editable = try DatabaseQueue(path: editedURL.path)
            try await editable.write { db in
                try db.execute(
                    sql: "UPDATE \(BackupService.metadataTableName) SET schemaVersion = 999, migrationIdentifier = 'v999_future'"
                )
            }

            await #expect(throws: BackupServiceError.newerSchema("v999_future")) {
                try await service.importGeneration(from: editedURL)
            }
        }

        @Test
        func restoreRejectsBackupWithUnexpectedTriggerBeforeSanitizingIt() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "BackupTrigger",
                endedAt: Date(timeIntervalSince1970: 1_776_384_060),
                duration: 60,
                batchCompletedAt: Date(timeIntervalSince1970: 1_776_384_070)
            )
            defer { fixture.removeFiles() }
            let service = BackupService(
                dbQueue: fixture.database.dbQueue,
                applicationSupportURL: fixture.testRootURL
            )
            let generation = try await service.createGeneration()
            let editable = try DatabaseQueue(path: generation.fileURL.path)
            try await editable.write { db in
                try db.execute(
                    sql: """
                    CREATE TRIGGER malicious_audio_delete
                    AFTER DELETE ON recording_audio_segments
                    BEGIN
                        DELETE FROM vaults;
                    END
                    """
                )
            }
            try editable.close()

            await #expect(throws: BackupServiceError.invalidBackup) {
                try await service.prepareRestore(from: generation)
            }
            let vaultCount = try await fixture.database.dbQueue.read { db in try VaultRecord.fetchCount(db) }
            #expect(vaultCount == 1)
        }

        @Test
        // swiftlint:disable:next function_body_length
        func restorePreparationMigratesKnownOlderSchemaAndPreservesData() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-old-backup-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let live = try AppDatabaseManager(path: rootURL.appending(path: "live.sqlite").path)
            let service = BackupService(dbQueue: live.dbQueue, applicationSupportURL: rootURL)

            let migrationIdentifier = "v17_calendarEventIntegrity"
            let oldURL = rootURL.appending(path: "old.sqlite")
            let oldQueue = try DatabaseQueue(path: oldURL.path)
            try AppDatabaseManager.migrator.migrate(oldQueue, upTo: migrationIdentifier)
            let vault = makeVault(name: "Preserved old vault", path: rootURL.appending(path: "Vault").path)
            let metadata = BackupMetadata(
                formatVersion: BackupMetadata.currentFormatVersion,
                generationId: .v7(),
                createdAt: .now,
                schemaVersion: try #require(AppDatabaseManager.schemaVersion(from: migrationIdentifier)),
                migrationIdentifier: migrationIdentifier,
                appVersion: "0.9.0",
                appBuild: "9",
                reason: .manual
            )
            try await oldQueue.write { db in
                try vault.insert(db)
                try db.execute(
                    sql: """
                    CREATE TABLE dahlia_backup_metadata (
                        formatVersion INTEGER NOT NULL, generationId TEXT NOT NULL,
                        createdAt DATETIME NOT NULL, schemaVersion INTEGER NOT NULL,
                        migrationIdentifier TEXT NOT NULL, appVersion TEXT NOT NULL,
                        appBuild TEXT NOT NULL, reason TEXT NOT NULL
                    )
                    """
                )
                try db.execute(
                    sql: """
                    INSERT INTO dahlia_backup_metadata
                        (formatVersion, generationId, createdAt, schemaVersion,
                         migrationIdentifier, appVersion, appBuild, reason)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        metadata.formatVersion, metadata.generationId.uuidString, metadata.createdAt,
                        metadata.schemaVersion, metadata.migrationIdentifier, metadata.appVersion,
                        metadata.appBuild, metadata.reason.rawValue,
                    ]
                )
            }
            try oldQueue.close()

            let imported = try await service.importGeneration(from: oldURL)
            let marker = try await service.prepareRestore(from: imported)
            let stagedURL = rootURL.appending(path: BackupService.restoreDirectoryName)
                .appending(path: marker.stagedFilename)
            let staged = try DatabaseQueue(path: stagedURL.path)
            let result = try await staged.read { db in
                (
                    try AppDatabaseManager.migrator.hasCompletedMigrations(db),
                    try AppDatabaseManager.hasExpectedCurrentSchema(db),
                    try String.fetchOne(db, sql: "SELECT name FROM vaults WHERE id = ?", arguments: [vault.id])
                )
            }
            #expect(result.0)
            #expect(result.1)
            #expect(result.2 == vault.name)
        }

        private func makeAudioSegment(fixture: BatchAudioTestFixture) -> RecordingAudioSegmentRecord {
            RecordingAudioSegmentRecord(
                id: .v7(),
                recordingSessionId: fixture.session.id,
                source: .microphone,
                segmentIndex: 0,
                generationId: .v7(),
                state: .ready,
                partialRelativePath: "session/microphone/0.partial.caf",
                finalRelativePath: "session/microphone/0.caf",
                sampleRate: 16_000,
                channelCount: 1,
                sealedFrameCount: 160,
                sessionStartOffsetSeconds: 0,
                sessionEndOffsetSeconds: 1,
                byteCount: 320,
                sha256: Data(repeating: 1, count: 32),
                finalizationStartedAt: fixture.now,
                integrityVerifiedAt: fixture.now,
                finalizedAt: fixture.now,
                purgeRequestedAt: nil,
                purgedAt: nil,
                failureStage: nil,
                failureCode: nil,
                createdAt: fixture.now,
                updatedAt: fixture.now
            )
        }

        private func makeVault(name: String, path: String) -> VaultRecord {
            VaultRecord(id: .v7(), path: path, name: name, createdAt: .now, lastOpenedAt: .now)
        }
    }
#endif
