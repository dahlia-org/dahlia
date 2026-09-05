#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct RemoteChangeAssociationTests {
        @Test(arguments: ["owner", "member"])
        func missingVaultOnlyDeletesMemberAudio(role: String) async throws {
            let (database, originalVault) = try await syncedDatabase()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("missing-vault-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let audioURL = directory.appendingPathComponent("audio.caf")
            let bytes = Data([1, 2, 3, 4])
            try bytes.write(to: audioURL)
            var changedVault = originalVault
            changedVault.path = directory.path
            changedVault.syncRole = role
            changedVault.syncRecoveryState = "pending"
            let vault = changedVault
            let connection = try #require(vault.syncConfirmedConnectionId)
            let meeting = MeetingRecord(id: .v7(), vaultId: vault.id, projectId: nil, name: "Recorded", createdAt: .now, updatedAt: .now)
            let session = RecordingSessionRecord(
                id: .v7(),
                meetingId: meeting.id,
                startedAt: .now,
                endedAt: .now,
                duration: 1,
                offsetSeconds: 0,
                createdAt: .now,
                updatedAt: .now
            )
            try await database.dbQueue.write { db in
                try vault.update(db)
                try meeting.insert(db)
                try session.insert(db)
                try db.execute(sql: """
                INSERT INTO recording_audio_files(id, recordingSessionId, source, relativePath, storageLocation, sampleRate, channelCount, createdAt, updatedAt)
                VALUES (?, ?, 'mic', 'audio.caf', 'vault', 16000, 1, ?, ?)
                """, arguments: [UUID.v7(), session.id, Date.now, Date.now])
            }
            if role == "owner" {
                #expect(try await !RemoteChangeApplier.removeRevokedMemberVault(
                    vaultId: vault.id,
                    expectedConnectionId: connection,
                    dbQueue: database.dbQueue
                ))
                #expect(try Data(contentsOf: audioURL) == bytes)
            }
            #expect(try await RemoteChangeApplier.reconcileMissingVault(
                vaultId: vault.id,
                expectedConnectionId: connection,
                dbQueue: database.dbQueue
            ))
            let saved = try await database.dbQueue.read { db in try VaultRecord.fetchOne(db, key: vault.id) }
            if role == "owner" {
                #expect(saved?.accountConnectionId == connection)
                #expect(saved?.syncConfirmedConnectionId == nil)
                #expect(saved?.syncRecoveryState == nil)
                #expect(try Data(contentsOf: audioURL) == bytes)
                #expect(try await database.dbQueue.read { db in try MeetingRecord.fetchOne(db, key: meeting.id) } != nil)
            } else {
                #expect(saved == nil)
                #expect(!FileManager.default.fileExists(atPath: audioURL.path))
            }
        }

        @Test(arguments: ["pending", "recording", "detached", "reconnected"])
        func missingOwnerVaultDefersRecoveryWhenLocalStateChanged(state: String) async throws {
            let (database, vault) = try await syncedDatabase()
            let connection = try #require(vault.syncConfirmedConnectionId)
            let generation = try #require(try await RemoteChangeApplier.recoveryGeneration(
                vaultId: vault.id,
                expectedConnectionId: connection,
                dbQueue: database.dbQueue
            ))
            try await database.dbQueue.write { db in
                switch state {
                case "pending":
                    try SyncTransactionRecorder.record(
                        vaultId: vault.id,
                        operations: [SyncInitialSnapshotBuilder.vaultOperation(vault, action: .update)],
                        in: db
                    )
                case "recording":
                    let meeting = MeetingRecord(id: .v7(), vaultId: vault.id, projectId: nil, name: "Recording", createdAt: .now, updatedAt: .now)
                    try meeting.insert(db)
                    try RecordingSessionRecord(
                        id: .v7(),
                        meetingId: meeting.id,
                        startedAt: .now,
                        endedAt: nil,
                        duration: nil,
                        offsetSeconds: 0,
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                case "reconnected":
                    try db.execute(sql: "UPDATE vaults SET syncConfirmedConnectionId = NULL WHERE id = ?", arguments: [vault.id])
                    try db.execute(sql: "UPDATE vaults SET syncConfirmedConnectionId = ? WHERE id = ?", arguments: [connection, vault.id])
                default:
                    try db.execute(sql: "UPDATE vaults SET accountConnectionId = NULL WHERE id = ?", arguments: [vault.id])
                }
            }
            #expect(try await !RemoteChangeApplier.reconcileMissingVault(
                vaultId: vault.id,
                expectedConnectionId: connection,
                dbQueue: database.dbQueue,
                expectedMutationGeneration: generation
            ))
            #expect(try await database.dbQueue.read { db in try VaultRecord.fetchOne(db, key: vault.id)?.syncConfirmedConnectionId } == connection)
        }

        @Test
        func revokedMemberVaultIsRemovedFromTheWorkingCopy() async throws {
            let (database, originalVault) = try await syncedDatabase()
            var memberVault = originalVault
            memberVault.syncRole = "member"
            let vault = memberVault
            let meeting = MeetingRecord(
                id: .v7(), vaultId: vault.id, projectId: nil, name: "Shared",
                createdAt: .now, updatedAt: .now
            )
            try await database.dbQueue.write { db in
                try vault.update(db)
                try meeting.insert(db)
            }

            #expect(try await RemoteChangeApplier.removeRevokedMemberVault(
                vaultId: vault.id,
                expectedConnectionId: #require(vault.syncConfirmedConnectionId),
                dbQueue: database.dbQueue
            ))
            #expect(try await database.dbQueue.read { db in try VaultRecord.fetchOne(db, key: vault.id) } == nil)
            #expect(try await database.dbQueue.read { db in try MeetingRecord.fetchOne(db, key: meeting.id) } == nil)
        }

        @Test
        func delayedRemoteResultsCannotCrossVaultConnectionChanges() async throws {
            let (database, vault) = try await syncedDatabase()
            let oldConnectionId = try #require(vault.syncConfirmedConnectionId)
            let project = ProjectRecord(
                id: .v7(), vaultId: vault.id, parentProjectId: nil,
                name: "Local project", createdAt: .now, projectType: .undefined
            )
            let meeting = MeetingRecord(
                id: .v7(), vaultId: vault.id, projectId: project.id,
                name: "Local meeting", createdAt: .now, updatedAt: .now
            )
            let screenshotId = UUID.v7()
            try await database.dbQueue.write { db in
                try project.insert(db)
                try meeting.insert(db)
            }
            #expect(try await RemoteChangeApplier.beginTranscript(
                meetingId: meeting.id,
                vaultId: vault.id,
                expectedConnectionId: oldConnectionId,
                dbQueue: database.dbQueue
            ))

            let repository = MeetingRepository(dbQueue: database.dbQueue)
            try await repository.resolveVaultsForSignOut(
                connectionID: oldConnectionId,
                disposition: .moveToLocalAccount
            )
            _ = try await repository.updateVaultName(id: vault.id, name: "Local after sign out")

            let remoteProject = SyncProjectSnapshot(
                projectId: project.id,
                parentProjectId: nil,
                name: "Late project",
                description: "",
                projectType: "undefined",
                revision: 2,
                createdAt: project.createdAt
            )
            let meetingRecord = try SyncJSON.decoder.decode(
                SyncCanonicalPayload.self,
                from: Data(
                    "{\"projectId\":\"\(project.id.uuidString.lowercased())\",\"name\":\"Late meeting\",\"status\":\"READY\",\"createdAt\":\"2026-09-03T00:00:00.000Z\",\"updatedAt\":\"2026-09-03T00:00:00.000Z\"}"
                        .utf8
                )
            )
            let screenshotRecord = try SyncJSON.decoder.decode(
                SyncCanonicalPayload.self,
                from: Data(
                    "{\"meetingId\":\"\(meeting.id.uuidString.lowercased())\",\"capturedAt\":\"2026-09-03T00:00:00.000Z\",\"contentType\":\"image/png\",\"contentHash\":\"late-hash\"}"
                        .utf8
                )
            )
            let changes: [SyncChangePage.Change] = [
                .init(sequence: 1, entity: .meeting, entityId: meeting.id, action: "upsert", revision: 2, record: meetingRecord),
                .init(sequence: 2, entity: .screenshot, entityId: screenshotId, action: "upsert", revision: 1, record: screenshotRecord),
            ]
            let transcript = SyncTranscriptPage.Segment(
                segmentId: .v7(), startTime: .now, endTime: nil, text: "Late transcript",
                isConfirmed: true, audioSource: "mic", speakerLabel: nil
            )

            #expect(try await !RemoteChangeApplier.reconcileProjectSnapshot(
                [remoteProject], vaultId: vault.id, expectedConnectionId: oldConnectionId,
                dbQueue: database.dbQueue
            ))
            #expect(try await !RemoteChangeApplier.apply(
                changes, screenshots: [screenshotId: Data([1, 2, 3])], transcripts: [:], cursor: "late-cursor",
                vaultId: vault.id, expectedConnectionId: oldConnectionId, dbQueue: database.dbQueue
            ))
            #expect(try await !RemoteChangeApplier.applyTranscriptPage(
                [transcript], meetingId: meeting.id, vaultId: vault.id,
                expectedConnectionId: oldConnectionId, dbQueue: database.dbQueue
            ))
            #expect(try await !RemoteChangeApplier.finishTranscript(
                meetingId: meeting.id, revision: 2, cursor: "late-transcript-cursor", vaultId: vault.id,
                expectedConnectionId: oldConnectionId, dbQueue: database.dbQueue
            ))
            #expect(try await !RemoteChangeApplier.finishReset(
                SyncResetSnapshot(canonicalChanges: []), cursor: "late-reset-cursor", vaultId: vault.id,
                expectedConnectionId: oldConnectionId, dbQueue: database.dbQueue
            ))
            #expect(try await !RemoteChangeApplier.advancePullCursor(
                "late-empty-page-cursor", vaultId: vault.id,
                expectedConnectionId: oldConnectionId, dbQueue: database.dbQueue
            ))

            let detachedState = try await database.dbQueue.read { db in
                try (
                    VaultRecord.fetchOne(db, key: vault.id),
                    ProjectRecord.fetchOne(db, key: project.id),
                    MeetingRecord.fetchOne(db, key: meeting.id),
                    MeetingScreenshotRecord.fetchOne(db, key: screenshotId),
                    Int.fetchOne(
                        db,
                        sql: "SELECT count(*) FROM transcript_segments WHERE meetingId = ?",
                        arguments: [meeting.id]
                    )
                )
            }
            #expect(detachedState.0?.name == "Local after sign out")
            #expect(detachedState.0?.accountConnectionId == nil)
            #expect(detachedState.0?.syncPullCursor == nil)
            #expect(detachedState.1?.name == "Local project")
            #expect(detachedState.2?.name == "Local meeting")
            #expect(detachedState.3 == nil)
            #expect(detachedState.4 == 0)

            let newConnection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://new-server.example.com", clientID: "desktop-client", createdAt: .now
            )
            try await database.dbQueue.write { db in
                try newConnection.insert(db)
                try db.execute(
                    sql: "UPDATE vaults SET accountConnectionId = ?, syncConfirmedConnectionId = ?, syncRole = 'member' WHERE id = ?",
                    arguments: [newConnection.id, newConnection.id, vault.id]
                )
            }
            #expect(try await !RemoteChangeApplier.removeRevokedMemberVault(
                vaultId: vault.id,
                expectedConnectionId: oldConnectionId,
                dbQueue: database.dbQueue
            ))
            #expect(try await database.dbQueue.read { db in try VaultRecord.fetchOne(db, key: vault.id) } != nil)
            #expect(try await !RemoteChangeApplier.apply(
                changes, screenshots: [screenshotId: Data([1, 2, 3])], transcripts: [:], cursor: "old-server-cursor",
                vaultId: vault.id, expectedConnectionId: oldConnectionId, dbQueue: database.dbQueue
            ))
            #expect(try await RemoteChangeApplier.apply(
                changes, screenshots: [screenshotId: Data([1, 2, 3])], transcripts: [:], cursor: "new-server-cursor",
                vaultId: vault.id, expectedConnectionId: newConnection.id, dbQueue: database.dbQueue
            ))
            #expect(try await database.dbQueue.read { db in
                try (
                    MeetingRecord.fetchOne(db, key: meeting.id)?.name,
                    MeetingScreenshotRecord.fetchOne(db, key: screenshotId) != nil,
                    String.fetchOne(
                        db,
                        sql: "SELECT syncPullCursor FROM vaults WHERE id = ?",
                        arguments: [vault.id]
                    )
                )
            } == ("Late meeting", true, "new-server-cursor"))
        }

        private func syncedDatabase() async throws -> (AppDatabaseManager, VaultRecord) {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "desktop-client", createdAt: .now
            )
            var vault = VaultRecord(
                id: .v7(), path: "/tmp/sync", name: "Sync", createdAt: .now, lastOpenedAt: .now
            )
            vault.accountConnectionId = connection.id
            vault.syncConfirmedConnectionId = connection.id
            let savedVault = vault
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try savedVault.insert(db)
            }
            return (database, savedVault)
        }
    }
#endif
