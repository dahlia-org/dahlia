#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct MeetingSyncMigrationTests {
        @Test
        func finalUnreleasedSchemaUsesFourDerivedStateFreeQueueTables() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let tables = try database.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'sync_%' ORDER BY name"
                )
            }
            #expect(tables == [
                "sync_entity_state",
                "sync_operations",
                "sync_transactions",
                "sync_transcript_patch_items",
            ])

            let cloudVaultExists = try database.dbQueue.read { db in
                try db.tableExists("cloud_vaults")
            }
            #expect(!cloudVaultExists)

            let transactionColumns = try database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('sync_transactions')")
            }
            #expect(!transactionColumns.contains("status"))
            #expect(!transactionColumns.contains("claimedAt"))

            let operationColumns = try database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('sync_operations')")
            }
            #expect(operationColumns.contains("attachmentBytes"))
            #expect(!operationColumns.contains("expectedRevision"))

            let stateColumns = try database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('sync_entity_state')")
            }
            #expect(stateColumns == ["vaultId", "entity", "entityId", "confirmedRevision"])
            let stateVaultForeignKey = try database.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT \"table\", \"from\", on_delete FROM pragma_foreign_key_list('sync_entity_state')"
                )
            }
            #expect(stateVaultForeignKey?["table"] as String? == "vaults")
            #expect(stateVaultForeignKey?["from"] as String? == "vaultId")
            #expect(stateVaultForeignKey?["on_delete"] as String? == "CASCADE")
        }

        @Test
        func recorderKeepsImmutablePayloadAttachmentAndVaultOrder() async throws {
            let (database, vault) = try await syncedDatabase()
            let firstId = UUID.v7()
            let secondId = UUID.v7()
            let attachment = SyncScreenshotAttachment(mimeType: "image/png", bytes: Data([1, 2, 3]))
            let first = SyncOperationDraft(
                id: firstId,
                entity: .screenshot,
                action: .upsert,
                entityId: UUID.v7(),
                payloadJSON: Data("{\"caption\":\"first\"}".utf8)
            )
            let second = SyncOperationDraft(
                id: secondId,
                entity: .meeting,
                action: .update,
                entityId: UUID.v7(),
                payloadJSON: Data("{\"name\":\"second\"}".utf8)
            )
            _ = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [first],
                    screenshotAttachments: [firstId: attachment],
                    in: db
                )
                try SyncTransactionRecorder.record(vaultId: vault.id, operations: [second], in: db)
            }

            let claimed = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(claimed.operations.map(\.id) == [firstId])
            #expect(claimed.operations.first?.payloadJSON == first.payloadJSON)
            #expect(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue) == nil)
            let stored = try #require(try await SyncTransactionQueue.screenshotAttachment(
                operationId: firstId,
                dbQueue: database.dbQueue
            ))
            #expect(stored.bytes == attachment.bytes)
            #expect(stored.sha256 == attachment.sha256)
        }

        @Test
        func blockedReasonIsThePersistentStoppedState() async throws {
            let (database, vault) = try await syncedDatabase()
            _ = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncOperationDraft(entity: .vault, action: .update, entityId: vault.id)],
                    in: db
                )
            }
            let claimed = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(
                claimed,
                reason: .conflict,
                response: Data("{}".utf8),
                dbQueue: database.dbQueue
            )
            #expect(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue) == nil)
            #expect(try await database.dbQueue.read { db in
                try String.fetchOne(db, sql: "SELECT blockedReason FROM sync_transactions WHERE id = ?", arguments: [claimed.id])
            } == "conflict")
        }

        @Test
        func acceptingServerVersionForcesCanonicalReconciliation() async throws {
            let (database, vault) = try await syncedDatabase()
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'vault', ?, 3)",
                    arguments: [vault.id, vault.id]
                )
                var edited = vault
                edited.name = "Rejected local name"
                try edited.update(db)
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncInitialSnapshotBuilder.vaultOperation(edited, action: .update)],
                    in: db
                )
            }
            let claimed = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(
                claimed,
                reason: .conflict,
                response: Data("""
                {"conflicts":[{"entity":"vault","id":"\(vault.id.uuidString)","serverRevision":4}]}
                """.utf8),
                dbQueue: database.dbQueue
            )

            try await SyncTransactionQueue.acceptServerVersion(vaultId: vault.id, dbQueue: database.dbQueue)

            let state = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions WHERE vaultId = ?", arguments: [vault.id]),
                    Int.fetchOne(db, sql: "SELECT count(*) FROM sync_entity_state WHERE vaultId = ?", arguments: [vault.id]),
                    VaultRecord.fetchOne(db, key: vault.id)?.syncPullCursor
                )
            }
            #expect(state.0 == 0)
            #expect(state.1 == 0)
            #expect(state.2 == nil)
        }

        @Test
        func reapplyingADeletedServerProjectRecreatesIt() async throws {
            let (database, vault) = try await syncedDatabase()
            let project = ProjectRecord(
                id: .v7(),
                vaultId: vault.id,
                parentProjectId: nil,
                name: "Restored",
                createdAt: .now,
                projectType: .undefined
            )
            try await database.dbQueue.write { db in
                try project.insert(db)
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'project', ?, 2)",
                    arguments: [vault.id, project.id]
                )
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncInitialSnapshotBuilder.projectOperation(project, action: .update)],
                    in: db
                )
            }
            let claimed = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(
                claimed,
                reason: .conflict,
                response: Data("""
                {"conflicts":[{"entity":"project","id":"\(project.id.uuidString)","serverRevision":null,"record":null}]}
                """.utf8),
                dbQueue: database.dbQueue
            )

            try await SyncTransactionQueue.reapplyLocalVersion(vaultId: vault.id, dbQueue: database.dbQueue)

            let retried = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            let operation = try #require(retried.operations.first)
            #expect(operation.entity == .project)
            #expect(operation.action == .create)
            #expect(operation.baseRevision == nil)
            let payload = try #require(operation.payloadJSON)
            let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            #expect(object["createdAt"] is String)
        }

        @Test
        func reapplyingADeletedMeetingRestoresItBeforeItsSummary() async throws {
            let (database, vault) = try await syncedDatabase()
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: nil,
                name: "Restored",
                createdAt: .now,
                updatedAt: .now
            )
            let summary = SummaryRecord(
                meetingId: meeting.id,
                title: "Summary",
                document: "{}",
                createdAt: .now
            )
            try await database.dbQueue.write { db in
                try meeting.insert(db)
                try summary.insert(db)
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'meeting', ?, 2), (?, 'summary', ?, 1)",
                    arguments: [vault.id, meeting.id, vault.id, meeting.id]
                )
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncInitialSnapshotBuilder.summaryOperation(summary, action: .upsert)],
                    in: db
                )
            }
            let claimed = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.block(
                claimed,
                reason: .conflict,
                response: Data("""
                {"conflicts":[{"entity":"summary","id":"\(meeting.id.uuidString)","serverRevision":null,"record":null}]}
                """.utf8),
                dbQueue: database.dbQueue
            )

            try await SyncTransactionQueue.reapplyLocalVersion(vaultId: vault.id, dbQueue: database.dbQueue)

            let operations = try database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT o.entity, o.action, o.baseRevision
                    FROM sync_operations o
                    JOIN sync_transactions t ON t.id = o.transactionId
                    WHERE t.vaultId = ? ORDER BY t.sequence, o.position
                    """,
                    arguments: [vault.id]
                )
            }
            #expect(operations.count == 2)
            #expect(operations[0]["entity"] as String == "meeting")
            #expect(operations[0]["action"] as String == "create")
            #expect(operations[0]["baseRevision"] as Int? == nil)
            #expect(operations[1]["entity"] as String == "summary")
            #expect(operations[1]["baseRevision"] as Int? == 0)
        }

        @Test
        func recorderQueuesOnlyConfirmedTranscriptSegments() async throws {
            let (database, vault) = try await syncedDatabase()
            let patch = SyncOperationDraft(entity: .transcript, action: .patch, entityId: UUID.v7())
            let segment = TranscriptSegmentRecord(
                id: .v7(),
                meetingId: patch.entityId,
                sessionId: nil,
                startTime: .now,
                endTime: nil,
                text: "preview",
                translatedText: nil,
                isConfirmed: false,
                audioSource: "mic",
                speakerLabel: nil,
                audioFeatureVersion: nil,
                audioActiveRmsDecibels: nil,
                audioMedianPitchHertz: nil,
                audioVoicedFrameRatio: nil,
                audioPitchSpreadHertz: nil
            )

            let transactionId = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [patch],
                    transcriptSegments: [patch.id: [SyncTranscriptPatchSegment(segment)]],
                    in: db
                )
            }

            #expect(transactionId == nil)
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions")
            } == 0)
        }

        @Test
        func disabledVaultStillClaimsServerReset() async throws {
            let (database, vault) = try await syncedDatabase()
            let transactionId = try #require(try await database.dbQueue.write { db in
                try db.execute(sql: "UPDATE vaults SET syncEnabled = 0 WHERE id = ?", arguments: [vault.id])
                return try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncOperationDraft(entity: .vault, action: .reset, entityId: vault.id)],
                    in: db
                )
            })

            #expect(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue)?.id == transactionId)
        }

        @Test
        func memberVaultRejectsLocalDomainTransactions() async throws {
            let (database, vault) = try await syncedDatabase()
            try await database.dbQueue.write { db in
                try db.execute(sql: "UPDATE vaults SET syncRole = 'member' WHERE id = ?", arguments: [vault.id])
            }

            await #expect(throws: SyncTransactionQueueError.self) {
                try await database.dbQueue.write { db in
                    try SyncTransactionRecorder.record(
                        vaultId: vault.id,
                        operations: [SyncOperationDraft(entity: .vault, action: .update, entityId: vault.id)],
                        in: db
                    )
                }
            }
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions")
            } == 0)
        }

        @Test
        func memberVaultDisablesRecordingBeforePersistenceStarts() async throws {
            let (database, originalVault) = try await syncedDatabase()
            var vault = originalVault
            vault.syncRole = "member"
            let settings = AppSettings()
            settings.currentVault = vault
            let sidebar = SidebarViewModel(settings: settings)
            sidebar.setAppDatabase(database)
            defer { sidebar.setAppDatabase(nil) }
            let viewModel = CaptionViewModel(
                availableInputDevicesProvider: { [MicrophoneDevice(id: 1, name: "Test Microphone")] },
                defaultInputDeviceIDProvider: { nil }
            )
            await viewModel.refreshAvailableMicrophones()
            let coordinator = RecordingCoordinator(
                viewModel: viewModel,
                sidebarViewModel: sidebar,
                mainWindowNavigation: MainWindowNavigation(
                    openMainWindow: {},
                    openMainWindowWithoutActivation: {}
                ),
                onRecordingDidStart: {},
                onRecordingDidStop: {}
            )

            #expect(viewModel.canBeginRecording)
            #expect(!coordinator.canStartNewMeeting)
        }

        @Test
        func remoteScreenshotUsesCanonicalAnalysisWithoutQueuingLocalAnalysis() async throws {
            let (database, vault) = try await syncedDatabase()
            let meeting = MeetingRecord(
                id: .v7(), vaultId: vault.id, projectId: nil, name: "Meeting",
                createdAt: .now, updatedAt: .now
            )
            let screenshotID = UUID.v7()
            let record = try SyncJSON.decoder.decode(
                SyncCanonicalPayload.self,
                from: Data("""
                {
                  "meetingId": "\(meeting.id.uuidString.lowercased())",
                  "capturedAt": "2026-09-03T00:00:00.000Z",
                  "contentType": "image/png",
                  "contentHash": "hash",
                  "ocrText": "canonical ocr",
                  "caption": "canonical caption"
                }
                """.utf8)
            )
            try await database.dbQueue.write { db in try meeting.insert(db) }

            #expect(try await RemoteChangeApplier.apply(
                [.init(sequence: 1, entity: .screenshot, entityId: screenshotID, action: "upsert", revision: 1, record: record)],
                screenshots: [screenshotID: Data([1, 2, 3])],
                transcripts: [:],
                cursor: nil,
                vaultId: vault.id,
                dbQueue: database.dbQueue
            ))
            let state = try await database.dbQueue.read { db in
                try (
                    Int.fetchOne(
                        db,
                        sql: "SELECT count(*) FROM search_index_jobs WHERE targetKind = 'screenshotAnalysis' AND targetKey = ?",
                        arguments: [screenshotID]
                    ),
                    Int.fetchOne(
                        db,
                        sql: "SELECT count(*) FROM search_documents WHERE kind = 'screenshot' AND sourceId = ?",
                        arguments: [screenshotID]
                    )
                )
            }
            #expect(state.0 == 0)
            #expect(state.1 == 1)
        }

        @Test
        func remoteTranscriptKeepsLocalOnlyAndUnconfirmedRows() async throws {
            let (database, vault) = try await syncedDatabase()
            let meeting = MeetingRecord(
                id: .v7(), vaultId: vault.id, projectId: nil, name: "Meeting",
                createdAt: .now, updatedAt: .now
            )
            let confirmedId = UUID.v7()
            let previewId = UUID.v7()
            try await database.dbQueue.write { db in
                try meeting.insert(db)
                try TranscriptSegmentRecord(
                    id: confirmedId, meetingId: meeting.id, sessionId: UUID.v7(), startTime: .now,
                    endTime: nil, text: "old", translatedText: "translation", isConfirmed: true,
                    audioSource: "mic", speakerLabel: nil, audioFeatureVersion: 1,
                    audioActiveRmsDecibels: -20, audioMedianPitchHertz: 180,
                    audioVoicedFrameRatio: 0.8, audioPitchSpreadHertz: 20
                ).insert(db)
                try TranscriptSegmentRecord(
                    id: previewId, meetingId: meeting.id, sessionId: UUID.v7(), startTime: .now,
                    endTime: nil, text: "preview", translatedText: nil, isConfirmed: false,
                    audioSource: "system", speakerLabel: nil, audioFeatureVersion: nil,
                    audioActiveRmsDecibels: nil, audioMedianPitchHertz: nil,
                    audioVoicedFrameRatio: nil, audioPitchSpreadHertz: nil
                ).insert(db)
                try RemoteChangeApplier.applyTranscript(
                    meetingId: meeting.id,
                    segments: [.init(
                        segmentId: confirmedId, startTime: .now, endTime: nil, text: "canonical",
                        isConfirmed: true, audioSource: "mic", speakerLabel: "Speaker"
                    )],
                    in: db
                )
            }

            let segments = try await database.dbQueue.read { db in
                try TranscriptSegmentRecord.filter(Column("meetingId") == meeting.id).fetchAll(db)
            }
            let confirmed = try #require(segments.first { $0.id == confirmedId })
            #expect(confirmed.text == "canonical")
            #expect(confirmed.translatedText == "translation")
            #expect(confirmed.audioFeatureVersion == 1)
            #expect(confirmed.speakerLabel == "Speaker")
            #expect(segments.contains { $0.id == previewId && !$0.isConfirmed })
        }

        @Test
        func transcriptSchemaSeparatesAudioSourceFromSpeakerLabel() throws {
            let queue = try DatabaseQueue(path: ":memory:")
            let source = UUID.v7()
            let result = try queue.write { db in
                try db.execute(sql: """
                CREATE TABLE vaults(id BLOB PRIMARY KEY);
                CREATE TABLE meetings(id BLOB PRIMARY KEY);
                CREATE TABLE dahlia_account_connections(id BLOB PRIMARY KEY);
                CREATE TABLE transcript_segments(
                    id BLOB PRIMARY KEY, meetingId BLOB NOT NULL, speakerLabel TEXT
                );
                INSERT INTO transcript_segments(id, meetingId, speakerLabel) VALUES (?, ?, 'mic');
                """, arguments: [source, UUID.v7()])
                try MeetingSyncMigration.migrate(in: db)
                return try (
                    Row.fetchOne(db, sql: "SELECT audioSource, speakerLabel FROM transcript_segments WHERE id = ?", arguments: [source]),
                    Row.fetchOne(db, sql: "SELECT \"notnull\" AS isNotNull FROM pragma_table_info('transcript_segments') WHERE name = 'speakerLabel'")
                )
            }
            #expect(result.0?["audioSource"] as String? == "mic")
            #expect(result.0?["speakerLabel"] as String? == nil)
            #expect(result.1?["isNotNull"] as Int? == 0)
        }

        @Test
        func derivesRevisionsAndPreservesLaterOptimisticStateOnAck() async throws {
            let (database, vault) = try await syncedDatabase()
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'vault', ?, 3)",
                    arguments: [vault.id, vault.id]
                )
                guard var first = try VaultRecord.fetchOne(db, key: vault.id) else {
                    throw SyncTransactionQueueError.invalidReceipt
                }
                first.name = "First local"
                try first.update(db)
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncInitialSnapshotBuilder.vaultOperation(first, action: .update)],
                    in: db
                )
                first.name = "Second local"
                try first.update(db)
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncInitialSnapshotBuilder.vaultOperation(first, action: .update)],
                    in: db
                )
            }
            let bases = try await database.dbQueue.read { db in
                try Int.fetchAll(db, sql: "SELECT baseRevision FROM sync_operations ORDER BY rowid")
            }
            #expect(bases == [3, 4])

            let claimed = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            try await SyncTransactionQueue.complete(
                claimed,
                response: SyncTransactionResponse(
                    id: claimed.id,
                    status: "committed",
                    cursor: "cursor-4",
                    records: [.init(
                        entity: .vault,
                        id: vault.id,
                        revision: 4,
                        record: .object(["name": .string("Canonical first")])
                    )]
                ),
                dbQueue: database.dbQueue
            )
            let state = try await database.dbQueue.read { db in
                try (
                    VaultRecord.fetchOne(db, key: vault.id)?.name,
                    Int.fetchOne(
                        db,
                        sql: "SELECT confirmedRevision FROM sync_entity_state WHERE vaultId = ? AND entity = 'vault'",
                        arguments: [vault.id]
                    ),
                    Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions WHERE vaultId = ?", arguments: [vault.id])
                )
            }
            #expect(state.0 == "Second local")
            #expect(state.1 == 4)
            #expect(state.2 == 1)
        }

        @Test
        func resetStopsNewRecordingAndClearsRemoteAssociationAfterAck() async throws {
            let (database, vault) = try await syncedDatabase()
            let resetId = try #require(try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncOperationDraft(entity: .vault, action: .reset, entityId: vault.id)],
                    in: db
                )
            })
            let ignored = try await database.dbQueue.write { db in
                try SyncTransactionRecorder.record(
                    vaultId: vault.id,
                    operations: [SyncOperationDraft(entity: .vault, action: .update, entityId: vault.id)],
                    in: db
                )
            }
            #expect(ignored == nil)

            let claimed = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(claimed.id == resetId)
            try await SyncTransactionQueue.complete(
                claimed,
                response: SyncTransactionResponse(
                    id: claimed.id,
                    status: "committed",
                    cursor: "reset-cursor",
                    records: [.init(entity: .vault, id: vault.id, revision: nil, record: nil)]
                ),
                dbQueue: database.dbQueue
            )
            let updated = try #require(try await database.dbQueue.read { db in
                try VaultRecord.fetchOne(db, key: vault.id)
            })
            #expect(!updated.syncEnabled)
            #expect(updated.syncConfirmedConnectionId == nil)
            #expect(updated.syncPullCursor == nil)
            #expect(updated.syncLastCommittedCursor == nil)
        }

        @Test
        func restoredVaultSeedsPullCursorPastItsAcknowledgedReset() async throws {
            let (database, vault) = try await syncedDatabase()
            try await SyncInitialSnapshotBuilder.prepareRestore(dbQueue: database.dbQueue)
            let reset = try #require(try await SyncTransactionQueue.claim(dbQueue: database.dbQueue))
            #expect(reset.operations.contains { $0.entity == .vault && $0.action == .reset })

            try await SyncTransactionQueue.complete(
                reset,
                response: SyncTransactionResponse(
                    id: reset.id,
                    status: "committed",
                    cursor: "reset-cursor",
                    records: [.init(entity: .vault, id: vault.id, revision: nil, record: nil)]
                ),
                dbQueue: database.dbQueue
            )

            let restored = try #require(try await database.dbQueue.read { db in
                try VaultRecord.fetchOne(db, key: vault.id)
            })
            #expect(restored.syncEnabled)
            #expect(restored.syncPullCursor == "reset-cursor")
            #expect(restored.syncLastCommittedCursor == "reset-cursor")
        }

        @Test
        func initialSnapshotIsDerivedWithoutASeparateBootstrapFlag() async throws {
            let (database, vault) = try await syncedDatabase()
            try await database.dbQueue.write { db in
                try SyncInitialSnapshotBuilder.enqueuePending(in: db)
                try SyncInitialSnapshotBuilder.enqueuePending(in: db)
            }
            let first = try database.dbQueue.read { db in
                let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions") ?? 0
                let operation = try Row.fetchOne(db, sql: "SELECT entity, action FROM sync_operations")
                return (count, operation)
            }
            #expect(first.0 == 1)
            #expect(first.1?["entity"] as String? == "vault")
            #expect(first.1?["action"] as String? == "create")

            try await database.dbQueue.write { db in
                try SyncTransactionQueue.discard(vaultId: vault.id, in: db)
                try db.execute(
                    sql: """
                    INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision)
                    VALUES (?, 'vault', ?, 1)
                    """,
                    arguments: [vault.id, vault.id]
                )
                try SyncInitialSnapshotBuilder.enqueuePending(in: db)
            }
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions")
            } == 0)
        }

        @Test
        func initialSnapshotSplitsLargeProjectCollectionsBelowTheRequestLimit() async throws {
            let (database, vault) = try await syncedDatabase()
            let description = String(repeating: "x", count: 20_000)
            try await database.dbQueue.write { db in
                for index in 0 ..< 330 {
                    try ProjectRecord(
                        id: .v7(),
                        vaultId: vault.id,
                        parentProjectId: nil,
                        name: "Project \(index)",
                        createdAt: .now,
                        description: description,
                        projectType: .undefined
                    ).insert(db)
                }
                try SyncInitialSnapshotBuilder.enqueue(vaultId: vault.id, in: db)
            }

            let batches = try database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT count(*) AS operationCount, sum(length(o.payloadJSON)) AS payloadBytes
                    FROM sync_transactions t
                    JOIN sync_operations o ON o.transactionId = t.id
                    WHERE o.entity = 'project'
                    GROUP BY t.id
                    """
                )
            }
            #expect(batches.count == 2)
            #expect(batches.reduce(0) { $0 + ($1["operationCount"] as Int) } == 330)
            #expect(batches.allSatisfy { ($0["payloadBytes"] as Int) < 8 * 1024 * 1024 })
        }

        @Test
        func freshPullCollapsesHistoryAndOrdersProjectDependenciesBeforeMeetings() throws {
            let rootId = UUID.v7()
            let childId = UUID.v7()
            let meetingId = UUID.v7()
            let deletedMeetingId = UUID.v7()
            let json = """
            {
              "items": [
                {"sequence":1,"entity":"meeting","entityId":"\(meetingId.uuidString.lowercased())","action":"upsert","revision":2,
                 "record":{"projectId":"\(childId.uuidString.lowercased())","name":"Current"}},
                {"sequence":2,"entity":"project","entityId":"\(childId.uuidString.lowercased())","action":"upsert","revision":1,
                 "record":{"parentProjectId":"\(rootId.uuidString.lowercased())","name":"Child"}},
                {"sequence":3,"entity":"project","entityId":"\(rootId.uuidString.lowercased())","action":"upsert","revision":1,
                 "record":{"name":"Root"}},
                {"sequence":4,"entity":"meeting","entityId":"\(meetingId.uuidString.lowercased())","action":"upsert","revision":3,
                 "record":{"projectId":"\(childId.uuidString.lowercased())","name":"Latest"}},
                {"sequence":5,"entity":"meeting","entityId":"\(deletedMeetingId.uuidString.lowercased())","action":"delete","revision":null,"record":null}
              ],
              "cursor":"v1.cursor",
              "hasMore":false
            }
            """
            let page = try SyncJSON.decoder.decode(SyncChangePage.self, from: Data(json.utf8))

            let changes = SyncWorker.initialSnapshotChanges(page.items)

            #expect(changes.map(\.entityId) == [rootId, childId, meetingId, deletedMeetingId])
            #expect(changes[2].revision == 3)
            #expect(changes.last?.action == "delete")
        }

        @Test
        func freshPullReconcilesExistingProjectsBeforeApplyingCanonicalHierarchy() async throws {
            let (database, vault) = try await syncedDatabase()
            let firstRoot = UUID.v7()
            let secondRoot = UUID.v7()
            let retiredChild = UUID.v7()
            let meetingId = UUID.v7()
            try await database.dbQueue.write { db in
                try ProjectRecord(
                    id: firstRoot,
                    vaultId: vault.id,
                    parentProjectId: nil,
                    name: "First",
                    createdAt: .now,
                    projectType: .undefined
                ).insert(db)
                try ProjectRecord(
                    id: secondRoot,
                    vaultId: vault.id,
                    parentProjectId: nil,
                    name: "Second",
                    createdAt: .now,
                    projectType: .undefined
                ).insert(db)
                try ProjectRecord(
                    id: retiredChild,
                    vaultId: vault.id,
                    parentProjectId: firstRoot,
                    name: "Retired",
                    createdAt: .now,
                    projectType: nil
                ).insert(db)
                try MeetingRecord(
                    id: meetingId,
                    vaultId: vault.id,
                    projectId: firstRoot,
                    name: "Meeting",
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
            }
            let snapshot = [
                SyncProjectSnapshot(
                    projectId: secondRoot,
                    parentProjectId: nil,
                    name: "Root",
                    description: "",
                    projectType: "undefined",
                    revision: 2,
                    createdAt: .now
                ),
                SyncProjectSnapshot(
                    projectId: firstRoot,
                    parentProjectId: secondRoot,
                    name: "Child",
                    description: "",
                    projectType: nil,
                    revision: 2,
                    createdAt: .now
                ),
            ]

            #expect(try await RemoteChangeApplier.reconcileProjectSnapshot(
                snapshot,
                vaultId: vault.id,
                dbQueue: database.dbQueue
            ))

            let projects = try await database.dbQueue.read { db in
                try ProjectRecord.filter(Column("vaultId") == vault.id).fetchAll(db)
            }
            #expect(Set(projects.map(\.id)) == Set([firstRoot, secondRoot]))
            #expect(projects.first(where: { $0.id == secondRoot })?.parentProjectId == nil)
            #expect(projects.first(where: { $0.id == firstRoot })?.parentProjectId == secondRoot)
            #expect(try await database.dbQueue.read { db in
                try MeetingRecord.fetchOne(db, key: meetingId)?.projectId
            } == firstRoot)
        }

        @Test
        func transcriptChunksStayBelowTheServerRequestLimit() throws {
            let meetingId = UUID.v7()
            let segments = (0 ..< 70).map { index in
                SyncTranscriptPatchSegment(TranscriptSegmentRecord(
                    id: .v7(),
                    meetingId: meetingId,
                    sessionId: nil,
                    startTime: Date(timeIntervalSince1970: Double(index)),
                    endTime: nil,
                    text: String(repeating: "x", count: 100_000),
                    translatedText: nil,
                    isConfirmed: true,
                    audioSource: "mic",
                    speakerLabel: nil,
                    audioFeatureVersion: nil,
                    audioActiveRmsDecibels: nil,
                    audioMedianPitchHertz: nil,
                    audioVoicedFrameRatio: nil,
                    audioPitchSpreadHertz: nil
                ))
            }

            let chunks = try SyncWorker.transcriptChunks(.init(segments: segments, deletions: []))
            let patches = try SyncWorker.transcriptPatches(
                .init(segments: segments, deletions: []),
                maximumChunks: 1
            )

            #expect(chunks.count > 1)
            #expect(chunks.allSatisfy { $0.data.count < 8 * 1024 * 1024 })
            #expect(chunks.reduce(0) { $0 + $1.body.segments.count } == segments.count)
            #expect(patches.count == chunks.count)
            #expect(patches.flatMap(\.segments).map(\.segmentId) == segments.map(\.segmentId))
            #expect(try patches.allSatisfy { try SyncWorker.transcriptChunks($0).count == 1 })
        }

        @Test
        func initialSnapshotDefersOnlyConstructionWhileRecordingIsActive() async throws {
            let (database, vault) = try await syncedDatabase()
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: nil,
                name: "Recording",
                createdAt: .now,
                updatedAt: .now
            )
            let session = RecordingSessionRecord(
                id: .v7(),
                meetingId: meeting.id,
                startedAt: .now,
                endedAt: nil,
                duration: nil,
                offsetSeconds: 0,
                createdAt: .now,
                updatedAt: .now
            )
            try await database.dbQueue.write { db in
                try meeting.insert(db)
                try session.insert(db)
                try SyncInitialSnapshotBuilder.enqueuePending(in: db)
            }
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions")
            } == 0)

            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE recording_sessions SET endedAt = ? WHERE id = ?",
                    arguments: [Date(), session.id]
                )
                try SyncInitialSnapshotBuilder.enqueuePending(in: db)
            }
            #expect(try await database.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions")
            } ?? 0 > 0)
        }

        @Test
        func initialSnapshotAtomicallyConfirmsItsConnectionBeforeQueuedChanges() async throws {
            let (database, originalVault) = try await syncedDatabase()
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE vaults SET syncConfirmedConnectionId = NULL, name = 'Latest' WHERE id = ?",
                    arguments: [originalVault.id]
                )
                let ignored = try SyncTransactionRecorder.record(
                    vaultId: originalVault.id,
                    operations: [SyncOperationDraft(entity: .vault, action: .update, entityId: originalVault.id)],
                    in: db
                )
                #expect(ignored == nil)

                try SyncInitialSnapshotBuilder.enqueuePending(in: db)
            }

            let state = try await database.dbQueue.read { db in
                try (
                    VaultRecord.fetchOne(db, key: originalVault.id)?.syncConfirmedConnectionId,
                    String.fetchOne(
                        db,
                        sql: "SELECT payloadJSON FROM sync_operations WHERE entity = 'vault' AND action = 'create'"
                    ),
                    Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions")
                )
            }
            #expect(state.0 == originalVault.accountConnectionId)
            #expect(state.1?.contains("Latest") == true)
            #expect(state.2 == 1)
        }

        private func syncedDatabase() async throws -> (AppDatabaseManager, VaultRecord) {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "desktop-client", createdAt: .now
            )
            var vault = VaultRecord(id: .v7(), path: "/tmp/sync", name: "Sync", createdAt: .now, lastOpenedAt: .now)
            vault.accountConnectionId = connection.id
            vault.syncConfirmedConnectionId = connection.id
            vault.syncEnabled = true
            let savedVault = vault
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try savedVault.insert(db)
            }
            return (database, savedVault)
        }
    }
#endif
