#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct RemoteChangeAssociationTests {
        @Test(arguments: ["admin", "viewer"])
        func missingWorkspaceOnlyDeletesMemberAudio(role: String) async throws {
            let (database, originalWorkspace) = try await syncedDatabase()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("missing-workspace-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let audioURL = directory.appendingPathComponent("audio.caf")
            let bytes = Data([1, 2, 3, 4])
            try bytes.write(to: audioURL)
            var changedWorkspace = originalWorkspace
            changedWorkspace.path = directory.path
            changedWorkspace.syncRole = role
            changedWorkspace.syncRecoveryState = "pending"
            let workspace = changedWorkspace
            let connection = try #require(workspace.syncConfirmedConnectionId)
            let meeting = MeetingRecord(id: .v7(), workspaceId: workspace.id, projectId: nil, name: "Recorded", createdAt: .now, updatedAt: .now)
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
                try workspace.update(db)
                try meeting.insert(db)
                try session.insert(db)
                try db.execute(sql: """
                INSERT INTO recording_audio_files(id, recordingSessionId, source, relativePath, storageLocation, sampleRate, channelCount, createdAt, updatedAt)
                VALUES (?, ?, 'mic', 'audio.caf', 'vault', 16000, 1, ?, ?)
                """, arguments: [UUID.v7(), session.id, Date.now, Date.now])
            }
            if role == "admin" {
                #expect(try await !RemoteChangeApplier.removeRevokedMemberWorkspace(
                    workspaceId: workspace.id,
                    expectedConnectionId: connection,
                    dbQueue: database.dbQueue
                ))
                #expect(try Data(contentsOf: audioURL) == bytes)
            }
            #expect(try await RemoteChangeApplier.reconcileMissingWorkspace(
                workspaceId: workspace.id,
                expectedConnectionId: connection,
                dbQueue: database.dbQueue
            ))
            let saved = try await database.dbQueue.read { db in try WorkspaceRecord.fetchOne(db, key: workspace.id) }
            if role == "admin" {
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
        func missingOwnerWorkspaceDefersRecoveryWhenLocalStateChanged(state: String) async throws {
            let (database, workspace) = try await syncedDatabase()
            let connection = try #require(workspace.syncConfirmedConnectionId)
            let generation = try #require(try await RemoteChangeApplier.recoveryGeneration(
                workspaceId: workspace.id,
                expectedConnectionId: connection,
                dbQueue: database.dbQueue
            ))
            try await database.dbQueue.write { db in
                switch state {
                case "pending":
                    try SyncTransactionRecorder.record(
                        workspaceId: workspace.id,
                        operations: [SyncInitialSnapshotBuilder.workspaceOperation(workspace, action: .update)],
                        in: db
                    )
                case "recording":
                    let meeting = MeetingRecord(
                        id: .v7(),
                        workspaceId: workspace.id,
                        projectId: nil,
                        name: "Recording",
                        createdAt: .now,
                        updatedAt: .now
                    )
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
                    try db.execute(sql: "UPDATE workspaces SET syncConfirmedConnectionId = NULL WHERE id = ?", arguments: [workspace.id])
                    try db.execute(sql: "UPDATE workspaces SET syncConfirmedConnectionId = ? WHERE id = ?", arguments: [connection, workspace.id])
                default:
                    try db.execute(
                        sql: "UPDATE workspaces SET accountConnectionId = NULL, organizationId = NULL WHERE id = ?",
                        arguments: [workspace.id]
                    )
                }
            }
            #expect(try await !RemoteChangeApplier.reconcileMissingWorkspace(
                workspaceId: workspace.id,
                expectedConnectionId: connection,
                dbQueue: database.dbQueue,
                expectedMutationGeneration: generation
            ))
            #expect(try await database.dbQueue.read { db in
                try WorkspaceRecord.fetchOne(db, key: workspace.id)?.syncConfirmedConnectionId
            } == connection)
        }

        @Test
        func revokedMemberWorkspaceIsRemovedFromTheWorkingCopy() async throws {
            let (database, originalWorkspace) = try await syncedDatabase()
            var memberWorkspace = originalWorkspace
            memberWorkspace.syncRole = "viewer"
            let workspace = memberWorkspace
            let meeting = MeetingRecord(
                id: .v7(), workspaceId: workspace.id, projectId: nil, name: "Shared",
                createdAt: .now, updatedAt: .now
            )
            try await database.dbQueue.write { db in
                try workspace.update(db)
                try meeting.insert(db)
            }

            #expect(try await RemoteChangeApplier.removeRevokedMemberWorkspace(
                workspaceId: workspace.id,
                expectedConnectionId: #require(workspace.syncConfirmedConnectionId),
                dbQueue: database.dbQueue
            ))
            #expect(try await database.dbQueue.read { db in try WorkspaceRecord.fetchOne(db, key: workspace.id) } == nil)
            #expect(try await database.dbQueue.read { db in try MeetingRecord.fetchOne(db, key: meeting.id) } == nil)
        }

        @Test
        func delayedRemoteResultsCannotCrossWorkspaceConnectionChanges() async throws {
            let (database, workspace) = try await syncedDatabase()
            let oldConnectionId = try #require(workspace.syncConfirmedConnectionId)
            let project = ProjectRecord(
                id: .v7(), workspaceId: workspace.id, parentProjectId: nil,
                name: "Local project", createdAt: .now, projectType: .undefined
            )
            let meeting = MeetingRecord(
                id: .v7(), workspaceId: workspace.id, projectId: project.id,
                name: "Local meeting", createdAt: .now, updatedAt: .now
            )
            let screenshotId = UUID.v7()
            try await database.dbQueue.write { db in
                try project.insert(db)
                try meeting.insert(db)
            }
            #expect(try await RemoteChangeApplier.beginTranscript(
                meetingId: meeting.id,
                workspaceId: workspace.id,
                expectedConnectionId: oldConnectionId,
                dbQueue: database.dbQueue
            ))

            let repository = MeetingRepository(dbQueue: database.dbQueue)
            // Model the completed transfer; its network/completeness boundary is covered by TextContentTests.
            try await database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM sync_entity_state WHERE workspace_id = ?", arguments: [workspace.id])
                try db.execute(sql: "DELETE FROM sync_content_state WHERE workspace_id = ?", arguments: [workspace.id])
                try db.execute(
                    sql: "UPDATE workspaces SET accountConnectionId = NULL, organizationId = NULL, syncConfirmedConnectionId = NULL, syncPullCursor = NULL WHERE id = ?",
                    arguments: [workspace.id]
                )
            }
            _ = try await repository.updateWorkspaceName(id: workspace.id, name: "Local after sign out")

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
            let changes = try [SyncChangePage.Change(
                sequence: 1,
                entity: .meeting,
                entityId: meeting.id,
                action: "upsert",
                revision: 2,
                record: meetingRecord
            )]
                + canonicalImageChanges(fileId: screenshotId, meetingId: meeting.id)
            let transcript = SyncTranscriptPage.Segment(
                segmentId: .v7(), startedAt: .now, endedAt: nil, text: "Late transcript",
                createdAt: nil, audioSource: "mic", speakerLabel: nil
            )

            #expect(try await !RemoteChangeApplier.reconcileProjectSnapshot(
                [remoteProject], workspaceId: workspace.id, expectedConnectionId: oldConnectionId,
                dbQueue: database.dbQueue
            ))
            #expect(try await !RemoteChangeApplier.apply(
                changes, screenshots: [screenshotId: Data([1, 2, 3])], transcripts: [:], cursor: "late-cursor",
                workspaceId: workspace.id, expectedConnectionId: oldConnectionId, dbQueue: database.dbQueue
            ))
            #expect(try await !RemoteChangeApplier.applyTranscriptPage(
                [transcript], meetingId: meeting.id, workspaceId: workspace.id,
                expectedConnectionId: oldConnectionId, dbQueue: database.dbQueue
            ))
            #expect(try await !RemoteChangeApplier.finishReset(
                SyncResetSnapshot(canonicalChanges: []), cursor: "late-reset-cursor", workspaceId: workspace.id,
                expectedConnectionId: oldConnectionId, dbQueue: database.dbQueue
            ))
            #expect(try await !RemoteChangeApplier.advancePullCursor(
                "late-empty-page-cursor", workspaceId: workspace.id,
                expectedConnectionId: oldConnectionId, dbQueue: database.dbQueue
            ))

            let detachedState = try await database.dbQueue.read { db in
                try (
                    WorkspaceRecord.fetchOne(db, key: workspace.id),
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
                    sql: "UPDATE workspaces SET accountConnectionId = ?, organizationId = COALESCE(organizationId, id), syncConfirmedConnectionId = ?, syncRole = 'viewer' WHERE id = ?",
                    arguments: [newConnection.id, newConnection.id, workspace.id]
                )
            }
            #expect(try await !RemoteChangeApplier.removeRevokedMemberWorkspace(
                workspaceId: workspace.id,
                expectedConnectionId: oldConnectionId,
                dbQueue: database.dbQueue
            ))
            #expect(try await database.dbQueue.read { db in try WorkspaceRecord.fetchOne(db, key: workspace.id) } != nil)
            #expect(try await !RemoteChangeApplier.apply(
                changes, screenshots: [screenshotId: Data([1, 2, 3])], transcripts: [:], cursor: "old-server-cursor",
                workspaceId: workspace.id, expectedConnectionId: oldConnectionId, dbQueue: database.dbQueue
            ))
            #expect(try await RemoteChangeApplier.apply(
                changes, screenshots: [screenshotId: Data([1, 2, 3])], transcripts: [:], cursor: "new-server-cursor",
                workspaceId: workspace.id, expectedConnectionId: newConnection.id, dbQueue: database.dbQueue
            ))
            #expect(try await database.dbQueue.read { db in
                try (
                    MeetingRecord.fetchOne(db, key: meeting.id)?.name,
                    MeetingScreenshotRecord.fetchOne(db, key: screenshotId) != nil,
                    String.fetchOne(
                        db,
                        sql: "SELECT syncPullCursor FROM workspaces WHERE id = ?",
                        arguments: [workspace.id]
                    )
                )
            } == ("Late meeting", true, "new-server-cursor"))
        }

        private func syncedDatabase() async throws -> (AppDatabaseManager, WorkspaceRecord) {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "desktop-client", createdAt: .now
            )
            var workspace = WorkspaceRecord(
                id: .v7(), path: "/tmp/sync", name: "Sync", createdAt: .now, lastOpenedAt: .now
            )
            workspace.accountConnectionId = connection.id
            if workspace.syncRole == nil { workspace.syncRole = "admin" }
            if workspace.organizationId == nil { workspace.organizationId = .v7() }
            workspace.syncConfirmedConnectionId = connection.id
            let savedWorkspace = workspace
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try savedWorkspace.insert(db)
            }
            return (database, savedWorkspace)
        }
    }
#endif
