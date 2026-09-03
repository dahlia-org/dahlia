#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct MeetingSyncMigrationTests {
        @Test
        func currentSchemaSyncsOnlyOriginalTranscriptText() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let result = try database.dbQueue.read { db in
                (
                    try db.tableExists("meeting_sync_jobs"),
                    try db.tableExists("meeting_sync_success"),
                    try String.fetchOne(
                        db,
                        sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = 'meeting_sync_queue_translation'"
                    ),
                    try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('vaults')"),
                    try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('screenshots')")
                )
            }
            #expect(result.0)
            #expect(result.1)
            #expect(result.2 == nil)
            #expect(result.3.contains("syncBulkDeleteApproved"))
            #expect(result.3.contains("syncDeletionConnectionId"))
            #expect(result.4.contains("syncUploadedConnectionId"))
            #expect(result.3.contains("name"))
            #expect(try database.dbQueue.read { db in try db.tableExists("sync_apply_context") })
            #expect(try database.dbQueue.read { db in try db.tableExists("cloud_vaults") })
            #expect(try database.dbQueue.read { db in try db.tableExists("vault_sync_jobs") })
            #expect(try database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('transcript_segments')")
                    .contains("audioSource")
            })
        }

        @Test
        func enablingSyncMarksBootstrapBeforeQueuedUploadsRun() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "desktop-client", createdAt: .now
            )
            var configuredVault = VaultRecord(
                id: .v7(), path: "/tmp/bootstrap", name: "Bootstrap", createdAt: .now, lastOpenedAt: .now
            )
            configuredVault.accountConnectionId = connection.id
            let vault = configuredVault
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try vault.insert(db)
            }

            let updated = try #require(try await repository.updateVaultSync(id: vault.id, isEnabled: true))
            #expect(updated.syncBootstrapPending)
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM vault_sync_jobs WHERE vaultId = ?", arguments: [vault.id])
            } == 1)
        }

        @Test
        func remoteApplyDoesNotRequeueDomainChanges() async throws {
            let (database, vault, meeting) = try await syncedMeetingDatabase()
            try await database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM vault_sync_jobs; DELETE FROM meeting_sync_jobs")
                try db.execute(sql: "INSERT INTO sync_apply_context(active) VALUES(1)")
                try db.execute(sql: "UPDATE vaults SET name = 'Remote' WHERE id = ?", arguments: [vault.id])
                try db.execute(sql: "UPDATE meetings SET name = 'Remote' WHERE id = ?", arguments: [meeting.id])
                try db.execute(sql: "DELETE FROM sync_apply_context")
            }
            let counts = try await database.dbQueue.read { db in
                (
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM vault_sync_jobs") ?? -1,
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM meeting_sync_jobs") ?? -1
                )
            }
            #expect(counts.0 == 0)
            #expect(counts.1 == 0)
        }

        @Test
        func audioSourceMigrationPreservesExistingRoutingAndClearsSpeakerLabel() throws {
            let queue = try DatabaseQueue()
            let segmentID = UUID.v7()
            try queue.write { db in
                try db.execute(sql: """
                CREATE TABLE vaults (id BLOB PRIMARY KEY, name TEXT, syncEnabled BOOLEAN DEFAULT 0);
                CREATE TABLE projects (
                    id BLOB PRIMARY KEY, vaultId BLOB, parentProjectId BLOB, name TEXT,
                    description TEXT, projectType TEXT, revision INTEGER
                );
                CREATE TABLE meetings (id BLOB PRIMARY KEY, vaultId BLOB, projectId BLOB);
                CREATE TABLE meeting_sync_jobs (
                    id INTEGER PRIMARY KEY, vaultId BLOB, meetingId BLOB, targetKind TEXT,
                    generation INTEGER DEFAULT 1, status TEXT DEFAULT 'pending', attempts INTEGER DEFAULT 0,
                    availableAt DATETIME, claimedAt DATETIME, leaseExpiresAt DATETIME,
                    lastErrorCode TEXT, updatedAt DATETIME,
                    UNIQUE(targetKind, meetingId)
                );
                CREATE TABLE transcript_segments (id BLOB PRIMARY KEY, speakerLabel TEXT);
                INSERT INTO transcript_segments(id, speakerLabel) VALUES (?, 'mic');
                """, arguments: [segmentID])
                try VaultProjectSyncMigration.migrate(in: db)
            }
            let row = try queue.read { db in
                try Row.fetchOne(db, sql: "SELECT audioSource, speakerLabel FROM transcript_segments WHERE id = ?", arguments: [segmentID])
            }
            #expect(row?["audioSource"] as String? == "mic")
            #expect(row?["speakerLabel"] as String? == nil)
        }

        @Test
        func deletingServerCopyClearsScreenshotUploadAcknowledgements() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "desktop-client", createdAt: .now
            )
            var vault = VaultRecord(id: .v7(), path: "/tmp/sync", name: "Sync", createdAt: .now, lastOpenedAt: .now)
            vault.accountConnectionId = connection.id
            vault.syncConfirmedConnectionId = connection.id
            vault.syncEnabled = true
            let meeting = MeetingRecord(id: .v7(), vaultId: vault.id, name: "Meeting", createdAt: .now, updatedAt: .now)
            var screenshot = MeetingScreenshotRecord(
                id: .v7(), meetingId: meeting.id, sessionId: nil, capturedAt: .now,
                imageData: Data([1]), mimeType: "image/png", ocrText: nil, caption: nil
            )
            screenshot.syncUploadedConnectionId = connection.id
            let savedVault = vault
            let savedScreenshot = screenshot
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try savedVault.insert(db)
                try meeting.insert(db)
                try savedScreenshot.insert(db)
            }

            _ = try await repository.requestServerVaultDeletion(id: savedVault.id)
            let screenshotId = savedScreenshot.id
            let state = try await database.dbQueue.read { db in
                (
                    try MeetingScreenshotRecord.fetchOne(db, key: screenshotId)?.syncUploadedConnectionId,
                    try VaultRecord.fetchOne(db, key: savedVault.id)?.syncDeletionConnectionId
                )
            }
            #expect(state.0 == nil)
            #expect(state.1 == connection.id)
            await #expect(throws: DahliaAccountConnectionError.self) {
                try await repository.deleteDahliaAccountConnection(id: connection.id)
            }

            let replacement = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://other.example.com", clientID: "desktop-client", createdAt: .now
            )
            try await database.dbQueue.write { db in try replacement.insert(db) }
            #expect(try await repository.updateVaultAccountConnection(
                id: savedVault.id,
                connectionID: replacement.id
            ) == nil)
        }

        @Test
        func switchingConnectionPreservesServerDeletionControl() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let original = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://original.example.com", clientID: "desktop-client", createdAt: .now
            )
            let replacement = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://replacement.example.com", clientID: "desktop-client", createdAt: .now
            )
            var vault = VaultRecord(id: .v7(), path: "/tmp/sync", name: "Sync", createdAt: .now, lastOpenedAt: .now)
            vault.accountConnectionId = original.id
            vault.syncConfirmedConnectionId = original.id
            vault.syncEnabled = true
            let savedVault = vault
            try await database.dbQueue.write { db in
                try original.insert(db)
                try replacement.insert(db)
                try savedVault.insert(db)
            }

            let switched = try #require(try await repository.updateVaultAccountConnection(
                id: savedVault.id,
                connectionID: replacement.id
            ))
            #expect(switched.accountConnectionId == replacement.id)
            #expect(switched.syncConfirmedConnectionId == original.id)
            #expect(!switched.syncEnabled)
            #expect(try await repository.updateVaultSync(id: savedVault.id, isEnabled: true) == nil)
            #expect(try await repository.connectionHasPendingServerDeletion(id: original.id))

            let deleting = try #require(try await repository.requestServerVaultDeletion(id: savedVault.id))
            #expect(deleting.syncDeletionConnectionId == original.id)
            await #expect(throws: DahliaAccountConnectionError.self) {
                try await repository.deleteDahliaAccountConnection(id: original.id)
            }
        }

        @Test
        func syncedVaultMustDeleteServerCopyBeforeLocalRemoval() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let connection = DahliaAccountConnectionRecord(
                id: .v7(),
                origin: "https://server.example.com",
                clientID: "desktop-client",
                createdAt: .now
            )
            try await repository.insertDahliaAccountConnection(connection)
            var vault = VaultRecord(
                id: .v7(),
                path: "/tmp/synced-vault",
                name: "Synced",
                createdAt: .now,
                lastOpenedAt: .now
            )
            vault.accountConnectionId = connection.id
            vault.syncConfirmedConnectionId = connection.id
            try repository.insertVault(vault)

            await #expect(throws: VaultDeletionError.self) {
                try await repository.deleteVaultSafely(id: vault.id)
            }
            #expect(try repository.fetchAllVaults().map(\.id) == [vault.id])
        }

        @Test
        func successfulSyncIsNotRequeuedUntilTheMeetingChanges() async throws {
            let (database, _, meeting) = try await syncedMeetingDatabase()
            let job = try #require(try await MeetingSyncQueue.claim(dbQueue: database.dbQueue))
            try await MeetingSyncQueue.complete(job, dbQueue: database.dbQueue)

            try await MeetingSyncQueue.reconcile(dbQueue: database.dbQueue)
            let vaultJob = try #require(try await MeetingSyncQueue.claimVault(dbQueue: database.dbQueue))
            try await MeetingSyncQueue.complete(vaultJob, dbQueue: database.dbQueue)
            #expect(try await MeetingSyncQueue.claim(dbQueue: database.dbQueue) == nil)

            try await database.dbQueue.write { db in try MeetingSyncQueue.enqueue(meetingId: meeting.id, in: db) }
            #expect(try await MeetingSyncQueue.claim(dbQueue: database.dbQueue) != nil)
        }

        @Test
        func transcriptChangeDuringUploadIsRequeued() async throws {
            let (database, _, meeting) = try await syncedMeetingDatabase()
            let job = try #require(try await MeetingSyncQueue.claim(dbQueue: database.dbQueue))
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO transcript_segments(id, meetingId, startTime, text, isConfirmed, audioSource)
                    VALUES (?, ?, ?, 'Late segment', 1, 'mic')
                    """,
                    arguments: [UUID.v7(), meeting.id, Date()]
                )
            }

            try await MeetingSyncQueue.complete(job, dbQueue: database.dbQueue)
            try await MeetingSyncQueue.reconcile(dbQueue: database.dbQueue)

            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM meeting_sync_jobs WHERE meetingId = ? AND targetKind = 'upload'",
                    arguments: [meeting.id]
                )
            } == 1)
        }

        @Test
        func serverDeletionResetsCanonicalStateBeforeRestoreReupload() async throws {
            let (database, vault, meeting) = try await syncedMeetingDatabase()
            let screenshot = MeetingScreenshotRecord(
                id: .v7(), meetingId: meeting.id, sessionId: nil, capturedAt: .now,
                imageData: Data([1]), mimeType: "image/png", ocrText: nil, caption: nil
            )
            try await database.dbQueue.write { db in
                try screenshot.insert(db)
                try db.execute(
                    sql: """
                    UPDATE vaults SET serverRevision = 4, syncCursor = 'v1.cursor',
                        syncConflictJSON = '{}', syncBootstrapPending = 1 WHERE id = ?;
                    UPDATE meetings SET serverRevision = 3, summaryServerRevision = 2,
                        transcriptServerRevision = 5, transcriptServerGeneration = 'generation' WHERE id = ?;
                    UPDATE screenshots SET serverRevision = 7, syncUploadedConnectionId = accountConnectionId
                    FROM vaults WHERE screenshots.id = ? AND vaults.id = ?;
                    INSERT INTO meeting_sync_success(meetingId, segmentCount, confirmedCount)
                    VALUES (?, 0, 0);
                    """,
                    arguments: [vault.id, meeting.id, screenshot.id, vault.id, meeting.id]
                )
            }

            try await MeetingSyncQueue.completeServerVaultDeletion(
                vaultId: vault.id,
                mode: .replaceAfterRestore,
                dbQueue: database.dbQueue
            )

            let state = try database.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: """
                    SELECT vaults.serverRevision AS vaultRevision, vaults.syncCursor,
                        vaults.syncConflictJSON, vaults.syncBootstrapPending,
                        meetings.serverRevision AS meetingRevision, meetings.summaryServerRevision,
                        meetings.transcriptServerRevision, meetings.transcriptServerGeneration,
                        screenshots.serverRevision AS screenshotRevision, screenshots.syncUploadedConnectionId,
                        (SELECT count(*) FROM vault_sync_jobs WHERE vaultId = vaults.id) AS vaultJobs,
                        (SELECT count(*) FROM meeting_sync_jobs WHERE vaultId = vaults.id) AS meetingJobs,
                        (SELECT count(*) FROM meeting_sync_success WHERE meetingId = meetings.id) AS successes
                    FROM vaults JOIN meetings ON meetings.vaultId = vaults.id
                    JOIN screenshots ON screenshots.meetingId = meetings.id
                    WHERE vaults.id = ?
                    """,
                    arguments: [vault.id]
                )
            }
            #expect(state?["vaultRevision"] as Int? == nil)
            #expect(state?["syncCursor"] as String? == nil)
            #expect(state?["syncConflictJSON"] as String? == nil)
            #expect(state?["syncBootstrapPending"] as Bool? == false)
            #expect(state?["meetingRevision"] as Int? == nil)
            #expect(state?["summaryServerRevision"] as Int? == 0)
            #expect(state?["transcriptServerRevision"] as Int? == 0)
            #expect(state?["transcriptServerGeneration"] as String? == nil)
            #expect(state?["screenshotRevision"] as Int? == nil)
            #expect(state?["syncUploadedConnectionId"] as UUID? == nil)
            #expect(state?["vaultJobs"] as Int? == 1)
            #expect(state?["meetingJobs"] as Int? == 1)
            #expect(state?["successes"] as Int? == 0)
        }

        @Test
        func pushAcknowledgementDoesNotAdvancePullCursor() async throws {
            let (database, vault, _) = try await syncedMeetingDatabase()
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE vaults SET syncCursor = 'v1.old' WHERE id = ?; INSERT INTO vault_sync_jobs(vaultId) VALUES (?)",
                    arguments: [vault.id, vault.id]
                )
            }
            let job = try #require(try await MeetingSyncQueue.claimVault(dbQueue: database.dbQueue))
            try await MeetingSyncQueue.complete(
                job,
                response: MeetingSyncTransactionResponse(
                    id: try #require(UUID(uuidString: job.transactionId)),
                    status: "committed",
                    cursor: "v1.new",
                    records: [.init(entity: "vault", id: vault.id, revision: 9, record: nil)]
                ),
                dbQueue: database.dbQueue
            )
            let state = try database.dbQueue.read { db in
                try Row.fetchOne(db, sql: "SELECT syncCursor, serverRevision FROM vaults WHERE id = ?", arguments: [vault.id])
            }
            #expect(state?["syncCursor"] as String? == "v1.old")
            #expect(state?["serverRevision"] as Int? == 9)
        }

        @Test
        func vaultManifestJobBlocksItsMeetingsUntilCompleted() async throws {
            let (database, vault, _) = try await syncedMeetingDatabase()
            try await MeetingSyncQueue.reconcile(dbQueue: database.dbQueue)

            #expect(try await MeetingSyncQueue.claim(dbQueue: database.dbQueue) == nil)
            let vaultJob = try #require(try await MeetingSyncQueue.claimVault(dbQueue: database.dbQueue))
            #expect(vaultJob.vaultId == vault.id)
            try await MeetingSyncQueue.complete(vaultJob, dbQueue: database.dbQueue)
            #expect(try await MeetingSyncQueue.claim(dbQueue: database.dbQueue) != nil)
        }

        @Test
        func permanentFailureWaitsForContentChange() async throws {
            let (database, _, meeting) = try await syncedMeetingDatabase()
            let job = try #require(try await MeetingSyncQueue.claim(dbQueue: database.dbQueue))
            try await MeetingSyncQueue.block(job, code: "http_413", dbQueue: database.dbQueue)
            #expect(try await MeetingSyncQueue.claim(dbQueue: database.dbQueue) == nil)

            try await database.dbQueue.write { db in try MeetingSyncQueue.enqueue(meetingId: meeting.id, in: db) }
            #expect(try await MeetingSyncQueue.claim(dbQueue: database.dbQueue) != nil)
        }

        @Test
        func oneHundredMeetingDeletesRequireOneApproval() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "desktop-client", createdAt: .now
            )
            var vault = VaultRecord(
                id: .v7(), path: "/tmp/sync", name: "Sync", createdAt: .now, lastOpenedAt: .now
            )
            vault.accountConnectionId = connection.id
            vault.syncConfirmedConnectionId = connection.id
            vault.syncEnabled = true
            let syncedVault = vault
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try syncedVault.insert(db)
                for _ in 0 ..< MeetingSyncQueue.meetingDeleteConfirmationThreshold {
                    try db.execute(
                        sql: "INSERT INTO meeting_sync_jobs(vaultId, meetingId, targetKind) VALUES (?, ?, 'meetingDelete')",
                        arguments: [syncedVault.id, UUID.v7()]
                    )
                }
            }

            #expect(try await MeetingSyncQueue.claim(dbQueue: database.dbQueue) == nil)
            #expect(try await repository.pendingMeetingDeletionCounts()[syncedVault.id] == 100)
            try await repository.approvePendingMeetingDeletions(vaultId: syncedVault.id)
            #expect(try await MeetingSyncQueue.claim(dbQueue: database.dbQueue) != nil)
        }

        @Test
        func activeBatchTranscriptionBlocksSyncUntilPersistenceFinishes() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "desktop-client", createdAt: .now
            )
            var vault = VaultRecord(id: .v7(), path: "/tmp/sync", name: "Sync", createdAt: .now, lastOpenedAt: .now)
            vault.accountConnectionId = connection.id
            vault.syncConfirmedConnectionId = connection.id
            vault.syncEnabled = true
            let meeting = MeetingRecord(
                id: .v7(), vaultId: vault.id, name: "Batch", createdAt: .now, updatedAt: .now
            )
            var session = RecordingSessionRecord(
                id: .v7(), meetingId: meeting.id, startedAt: .now, endedAt: .now,
                duration: 1, offsetSeconds: 0, createdAt: .now, updatedAt: .now,
                transcriptionMode: .batch
            )
            session.batchLastAttemptAt = .now
            let syncedVault = vault
            let activeSession = session
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try syncedVault.insert(db)
                try meeting.insert(db)
                try activeSession.insert(db)
            }

            #expect(try await MeetingSyncQueue.claim(dbQueue: database.dbQueue) == nil)
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE recording_sessions SET batchLastError = 'failed' WHERE id = ?",
                    arguments: [activeSession.id]
                )
            }
            #expect(try await MeetingSyncQueue.claim(dbQueue: database.dbQueue) != nil)
        }

        @Test
        func staleOpenRealtimeSessionDoesNotBlockSync() async throws {
            let (database, _, meeting) = try await syncedMeetingDatabase()
            let session = RecordingSessionRecord(
                id: .v7(), meetingId: meeting.id, startedAt: .now, endedAt: nil,
                duration: nil, offsetSeconds: 0, createdAt: .now, updatedAt: .now,
                transcriptionMode: .realtime
            )
            try await database.dbQueue.write { db in
                try session.insert(db)
            }

            #expect(try await MeetingSyncQueue.claim(dbQueue: database.dbQueue) != nil)
        }

        private func syncedMeetingDatabase() async throws -> (AppDatabaseManager, VaultRecord, MeetingRecord) {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "desktop-client", createdAt: .now
            )
            var vault = VaultRecord(
                id: .v7(), path: "/tmp/sync", name: "Sync", createdAt: .now, lastOpenedAt: .now
            )
            vault.accountConnectionId = connection.id
            vault.syncConfirmedConnectionId = connection.id
            vault.syncEnabled = true
            let meeting = MeetingRecord(
                id: .v7(), vaultId: vault.id, name: "Meeting", createdAt: .now, updatedAt: .now
            )
            let savedVault = vault
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try savedVault.insert(db)
                try meeting.insert(db)
            }
            return (database, savedVault, meeting)
        }
    }
#endif
