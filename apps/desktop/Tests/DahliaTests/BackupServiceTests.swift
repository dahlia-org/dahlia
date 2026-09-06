import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BackupServiceTests {
        @Test
        func generationFromWALDatabaseCanBeReadAfterMovingIntoPlace() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-wal-backup-\(UUID.v7().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let live = try AppDatabaseManager(
                path: rootURL.appending(path: "live.sqlite").path,
                enablesConcurrentSearch: true
            )
            defer { try? live.close() }
            let service = BackupService(dbQueue: live.dbQueue, applicationSupportURL: rootURL)
            let journalMode = try await live.dbQueue.read { db in
                try String.fetchOne(db, sql: "PRAGMA journal_mode")
            }

            let vault = makeVault(name: "WAL", path: rootURL.appending(path: "Vault").path)
            try await live.dbQueue.write { try vault.insert($0) }
            _ = try await service.createGeneration(vaultIds: [vault.id])

            #expect(journalMode?.lowercased() == "wal")
            #expect(try await service.listGenerations().first?.isValid == true)
        }

        @Test
        // swiftlint:disable:next function_body_length
        func generationEmbedsSchemaAndRemovesAudioReferences() async throws {
            let fixture = try BatchAudioTestFixture(
                name: "BackupSanitization",
                meetingStatus: .ready,
                endedAt: Date(timeIntervalSince1970: 1_776_384_060),
                duration: 60,
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
                audioSource: "mic"
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
            await fixture.database.searchIndexer.drain()

            let service = BackupService(
                dbQueue: fixture.database.dbQueue,
                applicationSupportURL: fixture.testRootURL,
                appVersion: "1.2.3",
                appBuild: "45"
            )
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
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
            #expect(items.first?.canTranscribe == false)
            #expect(items.first?.canStartTranscription == false)
            #expect(items.first?.isWorkInProgress == false)
            #expect(items.first?.canDiscard == true)
            #expect(items.first?.hasUnavailableAudio == true)
            #expect(items.first?.statusDescription == L10n.batchRecordingAudioUnavailable)
            await #expect(throws: BackupServiceError.unresolvedAudio(1)) {
                try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
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
                        "legacy/microphone.caf", 16000, 1, fixture.now, 160,
                        fixture.now, fixture.now, RecordingAudioStorageLocation.vault.rawValue,
                    ]
                )
            }
            let service = BackupService(
                dbQueue: fixture.database.dbQueue,
                applicationSupportURL: fixture.testRootURL
            )

            #expect(try await service.preflightItems().isEmpty)
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
            let backup = try DatabaseQueue(path: generation.fileURL.path)
            let legacyCount = try await backup.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recording_audio_files")
            }
            #expect(legacyCount == 0)
        }

        @Test
        func restorePreparationStagesVaultAndDefersSafetyBackupUntilStartup() async throws {
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
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])

            let marker = try await service.prepareRestore(from: generation, requests: [VaultBackupRestoreRequest(
                sourceVaultId: fixture.meeting.vaultId, targetVaultId: fixture.meeting.vaultId, mode: .overwrite, name: "Test"
            )])
            let generations = try await service.listGenerations()
            #expect(generations.count == 1)
            #expect(!generations.contains { $0.metadata?.reason == .beforeRestore })

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
                return hasMetadata && migrationsComplete && audioCount == 0
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
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
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
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
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
                try await service.prepareRestore(from: generation, requests: [VaultBackupRestoreRequest(
                    sourceVaultId: fixture.meeting.vaultId, targetVaultId: fixture.meeting.vaultId, mode: .overwrite, name: "Test"
                )])
            }
            let vaultCount = try await fixture.database.dbQueue.read { db in try VaultRecord.fetchCount(db) }
            #expect(vaultCount == 1)
        }

        @Test
        func importRejectsLegacyFormat() async throws {
            let fixture = try BatchAudioTestFixture(name: "LegacyBackup")
            defer { fixture.removeFiles() }
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
            let editable = try DatabaseQueue(path: generation.fileURL.path)
            try await editable.write { db in
                try db.execute(sql: "UPDATE dahlia_backup_metadata SET formatVersion = 1")
            }
            try editable.close()
            await #expect(throws: BackupServiceError.incompatibleFormat(1)) {
                try await service.importGeneration(from: generation.fileURL)
            }
        }

        @Test
        func unprocessedAudioInAnotherVaultDoesNotBlockBackup() async throws {
            let fixture = try BatchAudioTestFixture(name: "ScopedPreflight", endedAt: .now)
            defer { fixture.removeFiles() }
            let other = makeVault(name: "Other", path: fixture.testRootURL.appending(path: "Other").path)
            let segment = makeAudioSegment(fixture: fixture)
            try await fixture.database.dbQueue.write { db in
                try segment.insert(db)
                try other.insert(db)
            }
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            #expect(try await service.preflightItems(vaultId: other.id).isEmpty)
            let generation = try await service.createGeneration(vaultIds: [other.id])
            #expect(generation.metadata?.vaults.first?.id == other.id)
            await #expect(throws: BackupServiceError.unresolvedAudio(1)) {
                try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
            }
        }

        @Test
        func runningRetranscriptionBlocksRestoreEvenWithPreviousTranscript() async throws {
            let fixture = try BatchAudioTestFixture(name: "RetranscriptionBackup", endedAt: .now, batchCompletedAt: .now)
            defer { fixture.removeFiles() }
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
            let segment = makeAudioSegment(fixture: fixture)
            try await fixture.database.dbQueue.write { db in
                try segment.insert(db)
                try db.execute(
                    sql: "UPDATE recording_sessions SET batchLastAttemptAt = ? WHERE id = ?",
                    arguments: [Date().addingTimeInterval(1), fixture.session.id]
                )
            }
            #expect(try await service.hasProcessingAudio())
            await #expect(throws: BackupServiceError.unresolvedAudio(1)) {
                try await service.prepareRestore(from: generation, requests: [VaultBackupRestoreRequest(
                    sourceVaultId: fixture.meeting.vaultId, targetVaultId: .v7(), mode: .newVault, name: "New"
                )])
            }
        }

        @Test
        func malformedMetadataIsRejectedWithoutCrashing() async throws {
            let fixture = try BatchAudioTestFixture(name: "MalformedBackup")
            defer { fixture.removeFiles() }
            let service = BackupService(dbQueue: fixture.database.dbQueue, applicationSupportURL: fixture.testRootURL)
            let generation = try await service.createGeneration(vaultIds: [fixture.meeting.vaultId])
            let editable = try DatabaseQueue(path: generation.fileURL.path)
            try await editable.write { db in
                try db
                    .execute(
                        sql: "DROP TABLE dahlia_backup_metadata; CREATE TABLE dahlia_backup_metadata (formatVersion); INSERT INTO dahlia_backup_metadata VALUES (2)"
                    )
            }
            try editable.close()
            await #expect(throws: (any Error).self) { try await service.importGeneration(from: generation.fileURL) }
            #expect(try await service.listGenerations().first?.isValid == false)
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
                sampleRate: 16000,
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
