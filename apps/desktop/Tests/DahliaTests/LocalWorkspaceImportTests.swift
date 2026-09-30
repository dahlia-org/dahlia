#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct LocalWorkspaceImportTests {
        @Test(arguments: [false, true])
        func reconnectsExistingMeetingsWithoutUploadingAbsentRecords(sameWorkspace: Bool) async throws {
            let fixture = try LocalImportFixture(role: "admin")
            defer { fixture.close() }
            let snapshot = try await fixture.reconnection(sameWorkspace: sameWorkspace)
            try await fixture.database.dbQueue.write { db throws in
                let targetID = sameWorkspace ? fixture.source.id : fixture.target.id
                _ = try fixture.commit(reconnection: snapshot, sameWorkspace: sameWorkspace, in: db)
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id)?.workspaceId == targetID)
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id)?.name == "Server meeting")
                #expect(try WorkspaceRecord.fetchOne(db, key: targetID)?.syncPullCursor == (sameWorkspace ? "reconnected" : "complete"))
                #expect(try WorkspaceRecord.fetchOne(db, key: targetID)?.accountConnectionId == fixture.connection.id)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE entity IN ('project', 'meeting')") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations") == 0)
                #expect(try SummaryContent.fetchOne(db, key: fixture.meeting.id) == nil)
                #expect(try TranscriptRecord.fetchOne(db, key: fixture.meeting.id) == nil)
                #expect(try FileRecord.fetchOne(db, key: fixture.file.id) == nil)
                #expect(try MeetingAttachmentRecord.fetchOne(db, key: fixture.attachment.id) == nil)
                let savedSession = try #require(try RecordingSessionRecord.fetchOne(db, key: fixture.session.id))
                let savedMeeting = try #require(try MeetingRecord.fetchOne(db, key: savedSession.meetingId))
                #expect(savedMeeting.workspaceId == targetID)
                #expect(try RecordingArchiveRecord.fetchOne(db, key: fixture.session.id)?.connectionId == nil)
                #expect(try LocalWorkspaceImportRecord.fetchOne(db)?.backupPath == "/tmp/preserved-backup.dahlia")
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test(arguments: [false, true])
        func deletedServerHierarchyIsNotRecreatedAndPrivateNotesSurvive(sameWorkspace: Bool) async throws {
            let fixture = try LocalImportFixture(role: "admin")
            defer { fixture.close() }
            let snapshot = try await fixture.reconnection(sameWorkspace: sameWorkspace, emptyServer: true)
            try await fixture.database.dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO notes(meetingId, text, createdAt, updatedAt) VALUES (?, 'private note', ?, ?)",
                    arguments: [fixture.meeting.id, Date.now, Date.now]
                )
                _ = try fixture.commit(reconnection: snapshot, sameWorkspace: sameWorkspace, in: db)
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id) == nil)
                #expect(try ProjectRecord.fetchOne(db, key: fixture.root.id) == nil)
                #expect(try ProjectRecord.fetchOne(db, key: fixture.child.id) == nil)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_initial_builds") == 0)
                #expect(try String.fetchOne(
                    db,
                    sql: "SELECT json_extract(payload, '$.legacy') FROM document_local_archives WHERE meetingId = ?",
                    arguments: [fixture.meeting.id]
                ) == "private note")
                let archive = try #require(try RecordingArchiveRecord.fetchOne(db, key: fixture.session.id))
                #expect(archive.connectionId == nil)
                #expect(try WorkspaceRecord.fetchOne(db, key: archive.workspaceId)?.accountConnectionId == nil)
                #expect(try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM recording_audio_files WHERE recordingSessionId = ?",
                    arguments: [fixture.session.id]
                ) == 1)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test func reconnectsWhenTheDestinationSnapshotWasInterruptedByLocalIDs() async throws {
            let fixture = try LocalImportFixture(role: "admin")
            defer { fixture.close() }
            let snapshot = try await fixture.reconnection()
            try await fixture.database.dbQueue.write { db throws in
                try db.execute(
                    sql: "UPDATE workspaces SET syncPullCursor = NULL, syncRecoveryState = 'pending' WHERE id = ?",
                    arguments: [fixture.target.id]
                )
                _ = try fixture.commit(reconnection: snapshot, in: db)
                let workspace = try #require(try WorkspaceRecord.fetchOne(db, key: fixture.target.id))
                #expect(workspace.syncRecoveryState == nil)
                #expect(workspace.syncPullCursor == nil)
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id)?.workspaceId == fixture.target.id)
                #expect(try !SyncTransactionQueue.hasPending(workspaceId: fixture.target.id, in: db))
            }
        }

        @Test func reconnectionUsesServerContentWithoutRepublishingLocalChanges() async throws {
            let fixture = try LocalImportFixture(role: "admin")
            defer { fixture.close() }
            let snapshot = try await fixture.reconnection(includeSummary: true)
            try await fixture.database.dbQueue.write { db throws in
                _ = try fixture.commit(reconnection: snapshot, in: db)
                #expect(try SummaryContent.fetchOne(db, key: fixture.meeting.id)?.document == "Server summary")
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE entity = 'summary'") == 0)
                #expect(try Int.fetchOne(
                    db,
                    sql: "SELECT confirmedRevision FROM sync_entity_state WHERE workspace_id = ? AND entity = 'summary' AND entityId = ?",
                    arguments: [fixture.target.id, fixture.meeting.id]
                ) == 7)
            }
        }

        @Test func reconnectionDoesNotResurrectAServerDeletedSummary() async throws {
            let fixture = try LocalImportFixture(role: "admin")
            defer { fixture.close() }
            let snapshot = try await fixture.reconnection(deletedSummary: true)
            try await fixture.database.dbQueue.write { db throws in
                _ = try fixture.commit(reconnection: snapshot, in: db)
                #expect(try SummaryContent.fetchOne(db, key: fixture.meeting.id) == nil)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE entity = 'summary'") == 0)
                #expect(try Int.fetchOne(
                    db,
                    sql: "SELECT confirmedRevision FROM sync_entity_state WHERE workspace_id = ? AND entity = 'summary' AND entityId = ?",
                    arguments: [fixture.target.id, fixture.meeting.id]
                ) == 9)
            }
        }

        @Test func reconnectsPartiallyUploadedAudioWithoutUploadingMissingSources() async throws {
            let fixture = try LocalImportFixture(role: "admin")
            defer { fixture.close() }
            let snapshot = try await fixture.reconnection()
            let payload = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: JSONSerialization.data(withJSONObject: [
                "recordingNumber": 12, "meetingId": fixture.meeting.id.uuidString, "sessionId": fixture.session.id.uuidString,
                "startedAt": "2026-09-07T00:00:00Z", "endedAt": "2026-09-07T00:00:01Z",
                "audio": ["system": [
                    "contentType": "audio/mp4",
                    "size": 128,
                    "checksum": "SHA-256:" + String(repeating: "0", count: 64),
                    "contentUrl": "/api/v1/audio/system",
                    "manifest": ["sampleRate": 16000, "frameCount": 16000, "ranges": []],
                ]],
            ]))
            try await snapshot.store.merge([.init(
                sequence: 0,
                entity: .recording,
                entityId: fixture.session.id,
                action: "upsert",
                revision: 3,
                record: payload
            )])
            let complete = try await WorkspaceReconnectionSnapshot(
                store: snapshot.store,
                cursor: snapshot.cursor,
                ids: snapshot.store.resetSnapshot(),
                projects: snapshot.projects
            )
            try await fixture.database.dbQueue.write { db throws in
                _ = try fixture.commit(reconnection: complete, in: db)
                let archive = try #require(try RecordingArchiveRecord.fetchOne(db, key: fixture.session.id))
                #expect(archive.number == 12)
                #expect(try archive.audio["system"] != nil)
                #expect(archive.state == "remote")
                let payloads = try String.fetchAll(db, sql: "SELECT payloadJSON FROM sync_operations WHERE entity = 'recording'")
                #expect(payloads.isEmpty)
                #expect(archive.preparedJSON != "{}")
                #expect(try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM recording_audio_files WHERE recordingSessionId = ?",
                    arguments: [fixture.session.id]
                ) == 1)
            }
        }

        @Test func reconnectionRejectsRecordsOwnedByAnotherLocalWorkspace() async throws {
            let fixture = try LocalImportFixture(role: "admin")
            defer { fixture.close() }
            let snapshot = try await fixture.reconnection(sameWorkspace: true, includeForeignMeeting: true)
            await #expect(throws: LocalWorkspaceImportError.self) {
                try await fixture.database.dbQueue.write { db in
                    _ = try fixture.commit(reconnection: snapshot, sameWorkspace: true, in: db)
                }
            }
            try await fixture.database.dbQueue.read { db throws in
                #expect(try WorkspaceRecord.fetchOne(db, key: fixture.source.id)?.accountConnectionId == nil)
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id)?.name == fixture.meeting.name)
                #expect(try MeetingRecord.fetchOne(db, key: fixture.existing.id)?.workspaceId == fixture.target.id)
                #expect(try LocalWorkspaceImportRecord.fetchCount(db) == 0)
                #expect(try WorkspaceRecord.fetchCount(db) == 2)
                #expect(try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)?.meetingId == fixture.meeting.id)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations") == 0)
            }
        }

        @Test func importsUnattachedPrivateDocumentsWithoutPublishingThem() async throws {
            let fixture = try LocalImportFixture(role: "admin")
            defer { fixture.close() }
            let queue = fixture.database.dbQueue, id = UUID.v7()
            try await queue.write { db in
                try DocumentRecord(
                    id: id, workspaceId: fixture.source.id, meetingId: nil, kind: "general", title: "Private title",
                    checkpoint: "AAA=", text: "Retained projection", createdAt: .now, updatedAt: .now
                ).insert(db)
                _ = try fixture.commit(in: db)
                let copy = try #require(try DocumentPrivateCopyRecord.fetchOne(db))
                #expect(copy.workspaceId == fixture.target.id && copy.meetingId == nil && copy.kind == "general")
                #expect(copy.title == "Private title" && copy.text == "Retained projection" && copy.checkpoint == "AAA=")
                #expect(try DocumentRecord.fetchCount(db) == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE entity = 'document'") == 0)
                try WorkspaceRecord.deleteOne(db, key: fixture.source.id)
                #expect(try DocumentPrivateCopyRecord.fetchCount(db) == 1)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }

        @Test(arguments: ["admin", "editor"])
        func importsIntoANonemptyWorkspaceAndTracksOnlyInitialWork(role: String) async throws {
            let fixture = try LocalImportFixture(role: role)
            defer { fixture.close() }
            let queue = fixture.database.dbQueue
            try await queue.write { db in _ = try fixture.commit(in: db) }
            let operationIDs = try await queue.read { try Set(UUID.fetchAll($0, sql: "SELECT operationId FROM local_workspace_import_operations")) }
            #expect(operationIDs.count >= 7)
            try await queue.write { db throws in
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id)?.workspaceId == fixture.target.id)
                #expect(try ProjectRecord.fetchOne(db, key: fixture.child.id)?.parentProjectId == fixture.root.id)
                #expect(try FileRecord.fetchOne(db, key: fixture.file.id)?.workspaceId == fixture.target.id)
                #expect(try MeetingAttachmentRecord.fetchOne(db, key: fixture.attachment.id)?.fileId == fixture.file.id)
                #expect(try SummaryContent.fetchOne(db, key: fixture.meeting.id)?.document == "original summary")
                #expect(try String.fetchOne(
                    db,
                    sql: "SELECT text FROM transcript_segment_bodies WHERE segmentId = ?",
                    arguments: [fixture.segmentId]
                ) == "原文")
                #expect(try TranscriptSegmentRecord.fetchOne(db, key: fixture.segmentId)?.translatedText == "translation")
                #expect(try RecordingSessionRecord.fetchOne(db, key: fixture.session.id)?.meetingId == fixture.meeting.id)
                #expect(try String.fetchOne(db, sql: "SELECT original_workspace_path FROM recording_audio_files") == fixture.source.path)
                #expect(try RecordingArchiveRecord.fetchOne(db, key: fixture.session.id)?.connectionId == fixture.connection.id)
                #expect(try WorkspaceRecord.fetchOne(db, key: fixture.source.id)?.name == "Local settings")
                #expect(try WorkspaceRecord.fetchOne(db, key: fixture.target.id)?.name == "Existing settings")
                #expect(try MeetingRecord.fetchOne(db, key: fixture.existing.id) != nil)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE entity = 'workspace'") == 0)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                var edited = fixture.meeting
                edited.workspaceId = fixture.target.id
                edited.name = "Edited while importing"
                try edited.update(db)
                try SyncTransactionRecorder.record(workspaceId: fixture.target.id, operations: [
                    SyncInitialSnapshotBuilder.meetingOperation(edited, action: .update, in: db),
                ], in: db)
                let recording = RecordingSessionRecord(
                    id: .v7(),
                    meetingId: fixture.existing.id,
                    startedAt: .now,
                    offsetSeconds: 0,
                    createdAt: .now,
                    updatedAt: .now
                )
                try recording.insert(db)
            }
            // Reopening keeps operation IDs and the fixed import completion set.
            try queue.close()
            let reopened = try AppDatabaseManager(path: fixture.path).dbQueue
            defer { try? reopened.close() }
            #expect(try await reopened
                .read { try Set(UUID.fetchAll($0, sql: "SELECT operationId FROM local_workspace_import_operations")) } == operationIDs)
            while let transaction = try await SyncTransactionQueue.claim(dbQueue: reopened) {
                // The later edit may now overtake unrelated import work. Keep that request
                // leased to verify the fixed import can finish without its acknowledgement.
                guard transaction.operations.contains(where: { operationIDs.contains($0.id) }) else { continue }
                let records = try transaction.operations.map { operation in
                    let value: JSONValue? = operation.entity == .meeting
                        ? try SyncJSON.decoder.decode(
                            JSONValue.self,
                            from: Data("{\"name\":\"Original\",\"createdAt\":\"2026-09-01T00:00:00Z\",\"updatedAt\":\"2026-09-01T00:00:00Z\"}".utf8)
                        ) : nil
                    return SyncTransactionResponse.Record(entity: operation.entity, id: operation.entityId, revision: 1, record: value)
                }
                try await SyncTransactionQueue.complete(
                    transaction,
                    response: .init(id: transaction.id, status: "committed", cursor: "imported", records: records),
                    dbQueue: reopened
                )
            }
            try await reopened.read { db throws in
                #expect(try LocalWorkspaceImportRecord.fetchOne(db)?.completedAt != nil)
                #expect(try SyncTransactionQueue.hasPending(workspaceId: fixture.target.id, in: db))
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id)?.name == "Edited while importing")
                #expect(try RecordingSessionRecord.hasActiveRecording(workspaceId: fixture.target.id, in: db))
                #expect(try LocalWorkspaceImportRecord.fetchOne(db)?.backupPath == "/tmp/preserved-backup.dahlia")
            }
        }

        @Test
        func importsRetainedLocalCAFAsPendingServerArchive() async throws {
            let fixture = try LocalImportFixture(role: "editor")
            defer { fixture.close() }
            let segmentId = UUID.v7()
            try await fixture.database.dbQueue.write { db in
                try RecordingArchiveRecord.deleteOne(db, key: fixture.session.id)
                let now = Date.now
                try RecordingAudioSegmentRecord(
                    id: segmentId,
                    recordingSessionId: fixture.session.id,
                    source: .microphone,
                    segmentIndex: 1,
                    generationId: .v7(),
                    state: .ready,
                    partialRelativePath: "",
                    finalRelativePath: "recordings/retained.caf",
                    sampleRate: 16000,
                    channelCount: 1,
                    sealedFrameCount: 160,
                    sessionStartOffsetSeconds: 0,
                    sessionEndOffsetSeconds: 0.01,
                    byteCount: 1,
                    sha256: Data(repeating: 0, count: 32),
                    finalizationStartedAt: now,
                    integrityVerifiedAt: now,
                    finalizedAt: now,
                    purgeRequestedAt: nil,
                    purgedAt: nil,
                    failureStage: nil,
                    failureCode: nil,
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                try RecordingAudioSegmentRangeRecord(
                    id: .v7(),
                    audioSegmentId: segmentId,
                    startFrame: 0,
                    frameCount: 160,
                    sessionOffsetSeconds: 0,
                    localeIdentifier: "ja_JP",
                    createdAt: now,
                    updatedAt: now
                ).insert(db)
                _ = try fixture.commit(in: db)
            }

            let archive = try #require(try await fixture.database.dbQueue.read {
                try RecordingArchiveRecord.fetchOne($0, key: fixture.session.id)
            })
            #expect(archive.connectionId == fixture.connection.id)
            #expect(archive.state == "pending")
            #expect(archive.preparedJSON == "{}")
        }

        @Test
        func leavesExpiredLocalArchiveWithoutAudioExpired() async throws {
            let fixture = try LocalImportFixture(role: "editor")
            defer { fixture.close() }
            try await fixture.database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE recording_archives SET preparedJSON = '{}', state = 'expired' WHERE sessionId = ?",
                    arguments: [fixture.session.id]
                )
                _ = try fixture.commit(in: db)
                try db.execute(sql: "DELETE FROM sync_transactions WHERE workspace_id = ?", arguments: [fixture.target.id])
                let destination = CloudWorkspaceRecord(
                    workspaceId: fixture.target.id,
                    connectionId: fixture.connection.id,
                    organizationId: fixture.target.organizationId!,
                    name: fixture.target.name,
                    createdAt: fixture.target.createdAt,
                    revision: 1,
                    role: fixture.target.syncRole!
                )
                try LocalWorkspaceImport.validate(sourceId: fixture.source.id, destination: destination, in: db)
            }

            let archive = try #require(try await fixture.database.dbQueue.read {
                try RecordingArchiveRecord.fetchOne($0, key: fixture.session.id)
            })
            #expect(archive.connectionId == nil)
            #expect(archive.state == "expired")
        }

        @Test(arguments: [
            RecordingAudioSegmentState?.none,
            .some(.ready),
            .some(.recording),
            .some(.finalizing),
        ], [false, true])
        func importsMissingAudioMetadataButRejectsRetainedOrUnfinishedAudio(
            additionalState: RecordingAudioSegmentState?, hasExistingArchive: Bool
        ) throws {
            let fixture = try LocalImportFixture(role: "editor")
            defer { fixture.close() }
            try fixture.database.dbQueue.write { db in
                if hasExistingArchive {
                    try db.execute(
                        sql: "UPDATE recording_archives SET connectionId = ?, preparedJSON = '{}', state = 'pending' WHERE sessionId = ?",
                        arguments: [fixture.connection.id, fixture.session.id]
                    )
                } else {
                    try RecordingArchiveRecord.deleteOne(db, key: fixture.session.id)
                }
                let now = Date.now
                var segment = RecordingAudioSegmentRecord(
                    id: .v7(),
                    recordingSessionId: fixture.session.id,
                    source: .microphone,
                    segmentIndex: 1,
                    generationId: .v7(),
                    state: .failed,
                    partialRelativePath: "recordings/failed.partial.caf",
                    finalRelativePath: "recordings/failed.caf",
                    sampleRate: 16000,
                    channelCount: 1,
                    sealedFrameCount: 160,
                    sessionStartOffsetSeconds: 0,
                    sessionEndOffsetSeconds: 0.01,
                    byteCount: 1,
                    sha256: Data(repeating: 0, count: 32),
                    finalizationStartedAt: now,
                    integrityVerifiedAt: nil,
                    finalizedAt: now,
                    purgeRequestedAt: nil,
                    purgedAt: nil,
                    failureStage: "reconcileReady",
                    failureCode: "missingOrAmbiguousFile",
                    createdAt: now,
                    updatedAt: now
                )
                try segment.insert(db)
                if let additionalState {
                    segment.id = .v7()
                    segment.segmentIndex = 2
                    segment.generationId = .v7()
                    segment.state = additionalState
                    segment.partialRelativePath = ""
                    segment.finalRelativePath = "recordings/retained.caf"
                    segment.integrityVerifiedAt = additionalState == .ready ? now : nil
                    segment.failureStage = nil
                    segment.failureCode = nil
                    try segment.insert(db)
                }
            }

            let expectedWorkspaceId: UUID
            if additionalState != nil {
                #expect(throws: LocalWorkspaceImportError.self) {
                    try fixture.database.dbQueue.write { db in _ = try fixture.commit(in: db) }
                }
                expectedWorkspaceId = fixture.source.id
            } else {
                try fixture.database.dbQueue.write { db in _ = try fixture.commit(in: db) }
                expectedWorkspaceId = fixture.target.id
            }
            try fixture.database.dbQueue.read { db throws in
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id)?.workspaceId == expectedWorkspaceId)
                let archive = try RecordingArchiveRecord.fetchOne(db, key: fixture.session.id)
                #expect((archive != nil) == hasExistingArchive)
                if let archive {
                    #expect(archive.connectionId == fixture.connection.id)
                    #expect(archive.state == (additionalState == nil ? "expired" : "pending"))
                }
            }
        }

        @Test(arguments: ["collision", "pending", "blocked", "recording", "viewer", "unknown", "metadata", "connection", "rollback"])
        func failedPreflightAndCommitPreserveTheLocalWorkingCopy(reason: String) throws {
            let fixture = try LocalImportFixture(role: "editor")
            defer { fixture.close() }
            try fixture.database.dbQueue.write { db in
                if reason == "pending" || reason == "blocked" {
                    try SyncTransactionRecorder.record(
                        workspaceId: fixture.target.id,
                        operations: [SyncInitialSnapshotBuilder.meetingOperation(fixture.existing, action: .update, in: db)],
                        in: db
                    )
                    if reason == "blocked" { try db.execute(sql: "UPDATE sync_transactions SET blockedReason = 'conflict'") }
                } else if reason == "recording" {
                    try db.execute(sql: "UPDATE recording_sessions SET endedAt = NULL WHERE id = ?", arguments: [fixture.session.id])
                } else if reason == "viewer" || reason == "unknown" {
                    try db.execute(
                        sql: "UPDATE workspaces SET syncRole = ? WHERE id = ?",
                        arguments: [reason == "viewer" ? "viewer" : nil, fixture.target.id]
                    )
                } else if reason == "metadata" {
                    try db.execute(sql: "UPDATE workspaces SET syncPullCursor = NULL WHERE id = ?", arguments: [fixture.target.id])
                } else if reason == "connection" {
                    try db.execute(sql: "UPDATE workspaces SET syncConfirmedConnectionId = NULL WHERE id = ?", arguments: [fixture.target.id])
                } else if reason == "rollback" {
                    try db
                        .execute(
                            sql: "CREATE TRIGGER reject_import BEFORE INSERT ON sync_operations BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
                        )
                }
            }
            #expect(throws: (any Error).self) {
                try fixture.database.dbQueue.write { db in
                    _ = try fixture.commit(collision: reason == "collision", in: db)
                }
            }
            try fixture.database.dbQueue.read { db throws in
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id)?.workspaceId == fixture.source.id)
                #expect(try FileRecord.fetchOne(db, key: fixture.file.id)?.workspaceId == fixture.source.id)
                #expect(try RecordingArchiveRecord.fetchOne(db, key: fixture.session.id)?.connectionId == nil)
                #expect(try LocalWorkspaceImportRecord.fetchCount(db) == 0)
                #expect(try WorkspaceRecord.fetchCount(db) == 2)
            }
        }

        @Test(arguments: ["newRecords", "reconnect", "sameWorkspace"])
        func preparesARealBackupAndImageDespiteAnUnrelatedDatabaseWrite(mode: String) async throws {
            let reconnect = mode != "newRecords"
            let sameWorkspace = mode == "sameWorkspace"
            let fixture = try LocalImportFixture(role: "editor")
            defer { fixture.close() }
            let queue = fixture.database.dbQueue
            let destinationId = sameWorkspace ? fixture.source.id : fixture.target.id
            let bytes = try #require(TestScreenshotImageFixture.data(using: .png))
            try await queue.write { db in
                try db.execute(
                    sql: "UPDATE files SET size = ?, checksum = ? WHERE id = ?",
                    arguments: [bytes.count, "SHA-256:" + ScreenshotRemoteReference.digest(bytes), fixture.file.id]
                )
                try db.execute(sql: "INSERT INTO file_migration_content(fileId, imageData) VALUES (?, ?)", arguments: [fixture.file.id, bytes])
            }
            let files = try ScreenshotFileStore(directory: fixture.directory.appending(path: "FileStore"))
            let screenshots = ScreenshotContentProvider(cache: files)
            let workspace: [String: Any] = try [
                "workspaceId": destinationId.uuidString,
                "organizationId": #require(fixture.target.organizationId?.uuidString),
                "organizationName": "Organization",
                "meetingDeletionGraceDays": 7,
                "role": "editor",
                "name": "Existing settings",
                "generationSettings": JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.target.generationSettings)),
                "revision": 1,
                "createdAt": "2026-09-01T00:00:00Z",
                "updatedAt": "2026-09-01T00:00:00Z",
            ]
            let meeting: [String: Any] = [
                "meetingId": fixture.existing.id.uuidString,
                "workspaceId": destinationId.uuidString,
                "name": "Existing",
                "description": "",
                "projectId": NSNull(),
                "status": "READY",
                "revision": 1,
                "duration": NSNull(),
                "recordingStartedAt": NSNull(),
                "createdAt": "2026-09-01T00:00:00Z",
                "updatedAt": "2026-09-01T00:00:00Z",
            ]
            let listing = try JSONSerialization.data(withJSONObject: ["items": [workspace], "nextCursor": NSNull()])
            var snapshotItems: [[String: Any]] = [
                ["entity": "workspace", "id": destinationId.uuidString, "revision": 1, "record": workspace],
            ]
            if !sameWorkspace {
                snapshotItems.append(["entity": "meeting", "id": fixture.existing.id.uuidString, "revision": 1, "record": meeting])
            }
            if reconnect {
                var collision = meeting
                collision["meetingId"] = fixture.meeting.id.uuidString
                collision["name"] = "Server existing meeting"
                snapshotItems.append(["entity": "meeting", "id": fixture.meeting.id.uuidString, "revision": 1, "record": collision])
            }
            let snapshot = try JSONSerialization.data(withJSONObject: [
                "items": snapshotItems,
                "startCursor": "complete", "nextCursor": NSNull(),
            ])
            let connectionId = fixture.connection.id
            let unrelatedWriteCompleted = Mutex(false)
            ImageURLProtocol.register(origin: fixture.connection.origin) { request in
                switch request.url!.lastPathComponent {
                case "capabilities": return (200, [:], Data(#"{"documents":{"version":1},"sync":{"version":7}}"#.utf8))
                case "workspaces": return (200, [:], listing)
                case "snapshot":
                    do {
                        try queue.write {
                            try $0.execute(
                                sql: "UPDATE dahlia_account_connections SET syncDiscoveryErrorJSON = '{}' WHERE id = ?",
                                arguments: [connectionId]
                            )
                            try $0.execute(
                                sql: "UPDATE workspaces SET lastOpenedAt = lastOpenedAt WHERE id = ?",
                                arguments: [destinationId]
                            )
                        }
                        unrelatedWriteCompleted.withLock { $0 = true }
                    } catch {
                        return (500, [:], Data())
                    }
                    return (200, [:], snapshot)
                case "changes": return (200, [:], Data(#"{"items":[],"cursor":"complete","highWaterCursor":"complete","hasMore":false}"#.utf8))
                default: return (404, [:], Data())
                }
            }
            defer { ImageURLProtocol.remove(origin: fixture.connection.origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let api = SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in "test" })
            let destination = try CloudWorkspaceRecord(
                workspaceId: destinationId,
                connectionId: fixture.connection.id,
                organizationId: #require(fixture.target.organizationId),
                name: "Existing",
                createdAt: .now,
                revision: 1,
                role: "editor"
            )
            _ = try await LocalWorkspaceImport.run(
                sourceId: fixture.source.id,
                destination: destination,
                dbQueue: queue,
                backup: BackupService(dbQueue: queue, applicationSupportURL: fixture.directory),
                api: api,
                replaceServerImageAnalysis: true,
                reconnectExisting: reconnect,
                screenshots: screenshots
            )
            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: queue, screenshotContent: screenshots)
            #expect(unrelatedWriteCompleted.withLock { $0 })
            let record = try #require(try await queue.read { try LocalWorkspaceImportRecord.fetchOne($0) })
            #expect(FileManager.default.fileExists(atPath: record.backupPath))
            try BackupArchive.withExtracted(at: URL(filePath: record.backupPath)) { directory, _ in
                var configuration = Configuration()
                configuration.readonly = true
                let backup = try DatabaseQueue(path: directory.appending(path: "database.sqlite").path, configuration: configuration)
                defer { try? backup.close() }
                try backup.read { db throws in
                    #expect(try SummaryContent.fetchOne(db, key: fixture.meeting.id)?.document == "original summary")
                    #expect(try FileRecord.fetchOne(db, key: fixture.file.id) != nil)
                    #expect(try ProjectRecord.fetchOne(db, key: fixture.child.id) != nil)
                }
                #expect(try Data(contentsOf: directory.appending(path: "files/\(fixture.file.id.uuidString.lowercased())/original")) == bytes)
            }
            if !reconnect {
                #expect(try await screenshots.fileContent(id: fixture.file.id, dbQueue: queue).data == bytes)
            } else {
                #expect(try await queue.read { try FileRecord.fetchOne($0, key: fixture.file.id) } == nil)
            }
            #expect(try await queue.read { try MeetingRecord.fetchOne($0, key: fixture.meeting.id)?.workspaceId } == destinationId)
            if !reconnect {
                let filePayload = try await queue.read { db in
                    let value = try String.fetchOne(
                        db,
                        sql: "SELECT payloadJSON FROM sync_operations WHERE entity = 'file' LIMIT 1"
                    )
                    let json = try #require(value)
                    return try SyncJSON.decoder.decode(FileOperationPayload.self, from: Data(json.utf8))
                }
                #expect(filePayload.imageAnalysis == "replace")
            }
            if reconnect {
                #expect(try await queue.read { try MeetingRecord.fetchOne($0, key: fixture.meeting.id)?.name } == "Server existing meeting")
                let duplicateCreates = try await queue.read { db in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT count(*) FROM sync_operations WHERE entity = 'meeting' AND entityId = ?",
                        arguments: [fixture.meeting.id]
                    )
                }
                #expect(duplicateCreates == 0)
            }
        }

        @Test(arguments: [false, true])
        func laterDeletionCompletesTheFixedAudioOperationAfterItsReplacementReceipt(deletesHierarchy: Bool) async throws {
            let fixture = try LocalImportFixture(role: "editor")
            defer { fixture.close() }
            let queue = fixture.database.dbQueue
            try await queue.write { db in
                _ = try fixture.commit(in: db)
                if !deletesHierarchy {
                    try SyncTransactionRecorder.record(workspaceId: fixture.target.id, operations: [
                        .init(entity: .meeting, action: .delete, entityId: fixture.meeting.id),
                    ], in: db)
                    try MeetingRecord.deleteOne(db, key: fixture.meeting.id)
                }
            }
            if deletesHierarchy {
                let service = ProjectWorkspaceService(
                    repository: MeetingRepository(dbQueue: queue), workspace: fixture.target,
                    managedAudioRootURL: fixture.directory.appending(path: "managed-audio")
                )
                try await service.deleteProjectHierarchy(id: fixture.root.id, meetingDisposition: .deleteMeetings)
            }
            try await queue.read { db throws in
                #expect(try Int
                    .fetchOne(db, sql: "SELECT count(*) FROM local_workspace_import_operations WHERE replacementOperationId IS NOT NULL") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE entity = 'recording'") == 0)
            }
            while let transaction = try await SyncTransactionQueue.claim(dbQueue: queue) {
                if transaction.operations.contains(where: { $0.action == .delete }) {
                    #expect(try await queue.read { try LocalWorkspaceImportRecord.fetchOne($0)?.completedAt } == nil)
                }
                try await SyncTransactionQueue.complete(transaction, response: .init(
                    id: transaction.id,
                    status: "committed",
                    cursor: "done",
                    records: transaction.operations.map { .init(entity: $0.entity, id: $0.entityId, revision: 1, record: nil) }
                ), dbQueue: queue)
            }
            #expect(try await queue.read { try LocalWorkspaceImportRecord.fetchOne($0)?.completedAt } != nil)
        }

        @Test(arguments: ["conflict", "authorization"])
        func partialCommitStopsWithoutDiscardingTheRemainingImport(reason: String) async throws {
            let fixture = try LocalImportFixture(role: "editor")
            defer { fixture.close() }
            try await fixture.database.dbQueue.write { db in _ = try fixture.commit(in: db) }
            let first = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.database.dbQueue))
            let records = first.operations.map { SyncTransactionResponse.Record(entity: $0.entity, id: $0.entityId, revision: 1, record: nil) }
            try await SyncTransactionQueue.complete(
                first,
                response: .init(id: first.id, status: "committed", cursor: "partial", records: records),
                dbQueue: fixture.database.dbQueue
            )
            let next = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.database.dbQueue))
            try await SyncTransactionQueue.block(
                next,
                reason: reason == "conflict" ? .conflict : .authorization,
                response: Data("{}".utf8),
                dbQueue: fixture.database.dbQueue
            )
            #expect(try await SyncTransactionQueue.claim(dbQueue: fixture.database.dbQueue) == nil)
            try await fixture.database.dbQueue.read { db throws in
                #expect(try LocalWorkspaceImportRecord.fetchOne(db)?.completedAt == nil)
                #expect(try MeetingRecord.fetchOne(db, key: fixture.meeting.id)?.workspaceId == fixture.target.id)
                #expect(try WorkspaceRecord.fetchOne(db, key: fixture.source.id) != nil)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM local_workspace_import_operations WHERE completedAt IS NULL")! > 0)
            }
        }
    }

    @MainActor
    private struct LocalImportFixture {
        let directory: URL
        let database: AppDatabaseManager
        let connection: DahliaAccountConnectionRecord
        let source: WorkspaceRecord
        let target: WorkspaceRecord
        let root: ProjectRecord
        let child: ProjectRecord
        let meeting: MeetingRecord
        let existing: MeetingRecord
        let session: RecordingSessionRecord
        let file: FileRecord
        let attachment: MeetingAttachmentRecord
        let segmentId = UUID.v7()
        var path: String { directory.appending(path: "import.sqlite").path }

        init(role: String) throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID.v7().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = try AppDatabaseManager(path: directory.appending(path: "import.sqlite").path)
            connection = .init(id: .v7(), origin: "https://\(UUID.v7().uuidString.lowercased()).invalid", clientID: "test", createdAt: .now)
            source = .init(id: .v7(), path: "/tmp/local-import-source", name: "Local settings", createdAt: .now, lastOpenedAt: .now)
            target = .init(
                id: .v7(),
                path: nil,
                name: "Existing settings",
                createdAt: .now,
                lastOpenedAt: .now,
                accountConnectionId: connection.id,
                organizationId: .v7(),
                syncRole: role,
                syncConfirmedConnectionId: connection.id,
                syncPullCursor: "complete"
            )
            root = .init(id: .v7(), workspaceId: source.id, parentProjectId: nil, name: "Root", createdAt: .now, projectType: .undefined)
            child = .init(id: .v7(), workspaceId: source.id, parentProjectId: root.id, name: "Child", createdAt: .now, projectType: nil)
            meeting = .init(id: .v7(), workspaceId: source.id, projectId: child.id, name: "Original", createdAt: .now, updatedAt: .now)
            existing = .init(id: .v7(), workspaceId: target.id, projectId: nil, name: "Existing", createdAt: .now, updatedAt: .now)
            session = .init(
                id: .v7(),
                meetingId: meeting.id,
                startedAt: .now,
                endedAt: .now,
                duration: 1,
                offsetSeconds: 0,
                createdAt: .now,
                updatedAt: .now,
                transcriptionMode: .batch
            )
            file = .init(
                id: .v7(),
                workspaceId: source.id,
                size: 1,
                contentType: "image/png",
                checksum: "SHA-256:" + String(repeating: "a", count: 64),
                name: "image.png",
                metadata: .init(source: .screenshot),
                createdAt: .now,
                updatedAt: .now
            )
            attachment = .init(id: .v7(), meetingId: meeting.id, fileId: file.id, capturedAt: .now, sessionId: session.id, createdAt: .now)
            try database.dbQueue.write { db in
                try connection.insert(db)
                try source.insert(db)
                try target.insert(db)
                try root.insert(db)
                try child.insert(db)
                try meeting.insert(db)
                try existing.insert(db)
                try session.insert(db)
                try TranscriptRecord(meetingId: meeting.id, info: .init(
                    id: .v7(),
                    startedAt: .now,
                    endedAt: .now,
                    metadata: .init(provider: "apple", model: "apple-speech-live", runs: [])
                ))
                .insert(db)
                try TranscriptSegmentRecord(
                    id: segmentId,
                    meetingId: meeting.id,
                    sessionId: session.id,
                    startTime: .now,
                    endTime: .now,
                    translatedText: "translation"
                ).insert(db)
                try TranscriptSegmentBodyRecord(segmentId: segmentId, text: "原文").insert(db)
                try SummaryContent(meetingId: meeting.id, title: "Summary", document: "original summary", createdAt: .now).insert(db)
                try file.insert(db)
                try db.execute(sql: "INSERT INTO file_text_bodies(fileId, ocrText, caption) VALUES (?, 'OCR', 'Caption')", arguments: [file.id])
                try attachment.insert(db)
                let prepared = RecordingArchiveEncoder.Prepared(
                    relativePath: "archives/kept.m4a",
                    size: 1,
                    checksum: "SHA-256:" + String(repeating: "b", count: 64),
                    manifest: .init(sampleRate: 16000, frameCount: 1, ranges: [])
                )
                try RecordingArchiveRecord(
                    sessionId: session.id,
                    meetingId: meeting.id,
                    workspaceId: source.id,
                    preparedJSON: String(decoding: SyncJSON.encoder.encode(["mic": prepared]), as: UTF8.self),
                    state: "saved"
                )
                .insert(db)
                try db.execute(sql: """
                INSERT INTO recording_audio_files(id, recordingSessionId, source, relativePath, storageLocation, sampleRate, channelCount, createdAt, updatedAt)
                VALUES (?, ?, 'mic', 'audio.caf', 'vault', 16000, 1, ?, ?)
                """, arguments: [UUID.v7(), session.id, Date.now, Date.now])
            }
        }

        func reconnection(
            sameWorkspace: Bool = false,
            includeSummary: Bool = false,
            deletedSummary: Bool = false,
            includeForeignMeeting: Bool = false,
            emptyServer: Bool = false
        ) async throws -> WorkspaceReconnectionSnapshot {
            let changes = try await database.dbQueue.read { db -> [SyncChangePage.Change] in
                var workspace = sameWorkspace ? source : target
                workspace.organizationId = target.organizationId
                var serverMeeting = meeting
                serverMeeting.name = "Server meeting"
                var drafts = try [
                    SyncInitialSnapshotBuilder.workspaceOperation(workspace, action: .update),
                    SyncInitialSnapshotBuilder.projectOperation(root, action: .create),
                    SyncInitialSnapshotBuilder.projectOperation(child, action: .create),
                    SyncInitialSnapshotBuilder.meetingOperation(serverMeeting, action: .create, in: db),
                ]
                if emptyServer { drafts = Array(drafts.prefix(1)) }
                if includeForeignMeeting {
                    try drafts.append(SyncInitialSnapshotBuilder.meetingOperation(existing, action: .create, in: db))
                }
                if includeSummary {
                    try drafts.append(SyncInitialSnapshotBuilder.summaryOperation(
                        .init(meetingId: meeting.id, title: "Server", document: "Server summary", createdAt: .now),
                        action: .upsert
                    ))
                }
                return try drafts.map { draft in
                    var payload = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: draft.payloadJSON!)
                    if deletedSummary, draft.entity == .meeting {
                        payload.hasSummary = false
                        payload.summaryRevision = 9
                    }
                    return SyncChangePage.Change(
                        sequence: 0,
                        entity: draft.entity,
                        entityId: draft.entityId,
                        action: "upsert",
                        revision: 7,
                        record: payload
                    )
                }
            }
            let store = try SyncSnapshotStore()
            try await store.merge(changes)
            return try await WorkspaceReconnectionSnapshot(
                store: store,
                cursor: "reconnected",
                ids: store.resetSnapshot(),
                projects: store.projects()
            )
        }

        nonisolated func commit(
            collision: Bool = false,
            reconnection: WorkspaceReconnectionSnapshot? = nil,
            sameWorkspace: Bool = false,
            in db: Database
        ) throws -> WorkspaceRecord {
            let destination = CloudWorkspaceRecord(
                workspaceId: sameWorkspace ? source.id : target.id,
                connectionId: connection.id,
                organizationId: target.organizationId!,
                name: target.name,
                createdAt: target.createdAt,
                revision: 1,
                role: target.syncRole!
            )
            let reference = ScreenshotRemoteReference(
                origin: connection.origin,
                accountConnectionId: connection.id,
                fileId: file.id,
                contentHash: file.contentHash
            )
            let imported = try LocalWorkspaceImport.commit(
                sourceId: source.id,
                destination: destination,
                snapshot: reconnection?.ids ?? .init(ids: [.meeting: collision ? [meeting.id, existing.id] : [existing.id]]),
                files: [.init(
                    file: file,
                    reference: reference.jsonString()
                )],
                backupPath: "/tmp/preserved-backup.dahlia",
                reconnection: reconnection,
                in: db
            )
            // These tests assert the completed construction phase; separate scheduler tests
            // exercise editing and restart between individual construction commits.
            while try SyncInitialProgress.constructNext(workspaceId: imported.id, in: db) {}
            return imported
        }

        func close() { try? database.dbQueue.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }
#endif
