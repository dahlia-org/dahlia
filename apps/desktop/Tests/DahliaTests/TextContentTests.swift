#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct TextContentTests {
        @Test(arguments: [false, true])
        func migrationPreservesBodiesExportsAndLocalAttributes(serverAccount: Bool) throws {
            let queue = try DatabaseQueue()
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v45_screenshotContent")
            let meetingId = UUID.v7()
            let segmentId = UUID.v7()
            let vaultId = UUID.v7()
            let fileId = UUID.v7()
            let transactionId = UUID.v7()
            try queue.write { db in
                var vault = VaultRecord(id: vaultId, path: nil, name: "Existing", createdAt: .now, lastOpenedAt: .now)
                if serverAccount {
                    let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://migration.invalid", clientID: "test", createdAt: .now)
                    try connection.insert(db)
                    vault.accountConnectionId = connection.id
                    vault.syncConfirmedConnectionId = connection.id
                    try db.execute(
                        sql: "INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt) VALUES (?, ?, ?, ?, ?)",
                        arguments: [transactionId, vaultId, connection.id, Date(), Date()]
                    )
                    try db.execute(
                        sql: "INSERT INTO sync_operations(transactionId, position, id, entity, action, entityId, payloadJSON) VALUES (?, 0, ?, 'summary', 'upsert', ?, ?)",
                        arguments: [transactionId, UUID.v7(), meetingId, "pending body"]
                    )
                }
                try vault.insert(db)
                try MeetingRecord(id: meetingId, vaultId: vaultId, projectId: nil, name: "Existing", createdAt: .now, updatedAt: .now).insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO transcript_segments(id, meetingId, startTime, text, translatedText, isConfirmed, audioFeatureVersion, audioVoicedFrameRatio)
                    VALUES (?, ?, ?, ?, ?, 1, 1, 0.7)
                    """,
                    arguments: [segmentId, meetingId, Date(), "original 日本語", "translation"]
                )
                try db.execute(
                    sql: "INSERT INTO summaries(meetingId, title, document, createdAt) VALUES (?, ?, ?, ?)",
                    arguments: [meetingId, "Saved", "{\"version\":1}", Date()]
                )
                try SummaryExportRecord.setURL("vault:///saved.md", meetingId: meetingId, type: .vault, in: db)
                try MeetingNoteRecord(meetingId: meetingId, text: "user note", createdAt: .now, updatedAt: .now).insert(db)
                try ScreenshotContentMigration.FileRecord(
                    id: fileId, vaultId: vaultId, size: 0, contentType: "image/png",
                    checksum: "SHA-256:" + String(repeating: "0", count: 64), name: "image",
                    metadata: .init(source: .screenshot, width: 10, height: 20, ocrText: "OCR", caption: "caption"),
                    createdAt: .now, updatedAt: .now, localReference: "local original"
                ).insert(db)
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.write { db in
                let segment = try #require(try fetchTranscriptContent(id: segmentId, in: db))
                #expect(segment.text == "original 日本語")
                #expect(segment.translatedText == "translation")
                #expect(segment.audioVoicedFrameRatio == 0.7)
                #expect(try SummaryContent.fetchOne(db, key: meetingId)?.document == "{\"version\":1}")
                #expect(try SummaryExportRecord.fetchOne(meetingId: meetingId, type: .vault, in: db)?.url == "vault:///saved.md")
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                #expect(try !db.columns(in: "transcript_segments").contains { $0.name == "text" })
                #expect(try !db.columns(in: "summaries").contains { $0.name == "document" })
                #expect(try FileRecord.fetchOne(db, key: fileId)?.metadata.width == 10)
                #expect(try FileRecord.fetchOne(db, key: fileId)?.localReference == "local original")
                #expect(try TextContentAccess.fileText(fileId: fileId, in: db)?.ocrText == "OCR")
                #expect(try TextContentAccess.fileText(fileId: fileId, in: db)?.caption == "caption")
                #expect(try MeetingNoteRecord.fetchOne(db, key: meetingId)?.text == "user note")
                if serverAccount {
                    #expect(try String.fetchOne(
                        db,
                        sql: "SELECT payloadJSON FROM sync_operations WHERE transactionId = ?",
                        arguments: [transactionId]
                    ) == "pending body")
                    #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_content_state WHERE complete = 1 AND verifiedHash IS NULL") == 3)
                }
                try db.execute(sql: "DELETE FROM transcript_segment_bodies WHERE segmentId = ?", arguments: [segmentId])
                try db.execute(sql: "DELETE FROM summary_bodies WHERE meetingId = ?", arguments: [meetingId])
                #expect(throws: TextContentError.incomplete) { try TextContentAccess.requireComplete(entity: .transcript, id: meetingId, in: db) }
                #expect(throws: TextContentError.incomplete) { try TextContentAccess.requireComplete(entity: .summary, id: meetingId, in: db) }
                #expect(try SummaryExportRecord.fetchOne(meetingId: meetingId, type: .vault, in: db) != nil)
            }
        }

        @Test(arguments: ["file", "vault", "meeting", "meeting_file", "transcript", "other-file"])
        func recordingFileFetchProtectsOnlyRelatedPendingWrites(pending: String) async throws {
            let fixture = try textFixture()
            let fileId = UUID.v7()
            try await fixture.queue.write { db in
                try FileRecord(
                    id: fileId,
                    vaultId: fixture.vaultId,
                    size: 0,
                    contentType: "image/png",
                    checksum: "SHA-256:" + String(repeating: "a", count: 64),
                    name: "image",
                    metadata: .init(source: .screenshot),
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try MeetingFileRecord(id: fileId, meetingId: fixture.meetingId, fileId: fileId, capturedAt: .now, createdAt: .now).insert(db)
                try FileTextBodyRecord(fileId: fileId, ocrText: "local", caption: "local").save(db)
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'file', ?, 1)", arguments: [fixture.vaultId, fileId])
                try db.execute(
                    sql: "INSERT INTO sync_content_state(vaultId, entity, entityId, residentRevision, complete) VALUES (?, 'file', ?, 1, 1)",
                    arguments: [fixture.vaultId, fileId]
                )
                let entity: SyncEntity = pending == "other-file" ? .file : try #require(SyncEntity(rawValue: pending))
                let id = switch pending {
                case "vault": fixture.vaultId
                case "meeting", "transcript": fixture.meetingId
                case "other-file": UUID.v7()
                default: fileId
                }
                // An immutable queued deletion is enough to exercise the entity boundary.
                try SyncTransactionRecorder.record(
                    vaultId: fixture.vaultId,
                    operations: [.init(entity: entity, action: .delete, entityId: id)],
                    in: db
                )
                let expected = try #require(try TextContentStore.source(entity: .file, id: fileId, in: db))
                #expect(try TextContentStore.mayFetch(expected, entity: .file, id: fileId, in: db) == ["transcript", "other-file"].contains(pending))
                #expect(try !TextContentStore.mayReplace(expected, entity: .file, id: fileId, in: db))
                try db.execute(sql: "UPDATE files SET checksum = ? WHERE id = ?", arguments: ["SHA-256:" + String(repeating: "b", count: 64), fileId])
                #expect(try !TextContentStore.mayFetch(expected, entity: .file, id: fileId, in: db))
            }
        }

        @Test
        func recordingFileAnalysisUsesSyncedRevisionWithoutAdvancingCursor() async throws {
            let fixture = try textFixture()
            let fileId = UUID.v7()
            let sessionId = UUID.v7()
            let checksum = "SHA-256:" + String(repeating: "a", count: 64)
            let header: [String: Any] = [
                "id": fileId.uuidString, "vaultId": fixture.vaultId.uuidString, "revision": 2,
                "contentOmitted": true, "contentPresent": true, "contentCount": 2,
                "uri": "/Volumes/test/app/files/original", "offset": 0, "size": 3, "content_type": "image/png",
                "checksum": checksum,
                "name": "image", "metadata": ["source": "screenshot"],
                "createdAt": "2026-01-01T00:00:00.000Z", "updatedAt": "2026-01-01T00:00:01.000Z",
            ]
            let headerData = try JSONSerialization.data(withJSONObject: header)
            let bodyData = try JSONSerialization.data(withJSONObject: header.merging([
                "metadata": ["source": "screenshot", "ocr_text": "", "caption": "Server caption during recording"],
            ]) { _, new in new })
            let connectionId = try await fixture.queue.write { db -> UUID in
                let connectionId = try #require(try VaultRecord.fetchOne(db, key: fixture.vaultId)?.accountConnectionId)
                let reference = try ScreenshotRemoteReference(
                    origin: fixture.origin,
                    accountConnectionId: connectionId,
                    fileId: fileId,
                    contentHash: String(repeating: "a", count: 64)
                ).jsonString()
                try FileRecord(
                    id: fileId,
                    vaultId: fixture.vaultId,
                    size: 3,
                    contentType: "image/png",
                    checksum: checksum,
                    name: "image",
                    metadata: .init(source: .screenshot),
                    createdAt: .now,
                    updatedAt: .now,
                    localReference: reference,
                    remoteReference: reference
                ).insert(db)
                try MeetingFileRecord(id: fileId, meetingId: fixture.meetingId, fileId: fileId, capturedAt: .now, createdAt: .now).insert(db)
                try FileTextBodyRecord(fileId: fileId, ocrText: nil, caption: nil).save(db)
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'file', ?, 1)", arguments: [fixture.vaultId, fileId])
                try db.execute(
                    sql: "INSERT INTO sync_content_state(vaultId, entity, entityId, residentRevision, complete) VALUES (?, 'file', ?, 1, 1)",
                    arguments: [fixture.vaultId, fileId]
                )
                try db.execute(sql: "UPDATE vaults SET syncPullCursor = 'before'")
                try RecordingSessionRecord(
                    id: sessionId,
                    meetingId: fixture.meetingId,
                    startedAt: .now,
                    endedAt: nil,
                    duration: nil,
                    offsetSeconds: 0,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                try db.execute(
                    sql: "INSERT INTO transcript_segment_bodies(segmentId, text) VALUES (?, 'local recording')",
                    arguments: [fixture.segmentId]
                )
                try db.execute(sql: "UPDATE sync_content_state SET complete = 1, residentRevision = 3, contentCount = 1 WHERE entity = 'transcript'")
                let patch = SyncOperationDraft(entity: .transcript, action: .patch, entityId: fixture.meetingId)
                let segment = try #require(try fetchTranscriptContent(id: fixture.segmentId, in: db))
                try SyncTransactionRecorder.record(
                    vaultId: fixture.vaultId,
                    operations: [patch],
                    transcriptSegments: [patch.id: [.init(segment)]],
                    in: db
                )
                return connectionId
            }
            let calls = Mutex<[String]>([])
            let provider = provider(fixture) { request in
                calls.withLock { $0.append(request.url!.path) }
                #expect(request.url!.path == "/api/v1/files/\(fileId.uuidString.lowercased())/metadata")
                #expect(request.url!.query == nil)
                return (200, [:], bodyData)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let viewModel = CaptionViewModel()
            viewModel.loadMeeting(fixture.meetingId, dbQueue: fixture.queue, projectURL: nil, projectId: nil, vaultURL: nil)
            defer { viewModel.clearCurrentMeeting() }
            let pending = await viewModel.screenshotOCRState(id: fileId, contentProvider: provider)
            #expect(pending == .remote(ocrText: nil, caption: nil, state: .ready))
            #expect(!pending.isTerminal)
            let context = try await fixture.queue.read { db in
                try RemoteChangePolicy.Context(
                    vaultId: fixture.vaultId,
                    connectionId: connectionId,
                    generation: #require(try Int64.fetchOne(db, sql: "SELECT syncMutationGeneration FROM vaults"))
                )
            }
            let record = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: headerData)
            #expect(try await RemoteChangeApplier.applyIncremental(
                .init(sequence: 2, entity: .file, entityId: fileId, action: "upsert", revision: 2, record: record),
                context: context, dbQueue: fixture.queue
            ) == .applied)
            let completed = await viewModel.screenshotOCRState(id: fileId, refresh: true, contentProvider: provider)
            #expect(completed == .remote(ocrText: "", caption: "Server caption during recording", state: .ready))
            #expect(completed.isTerminal)
            #expect(calls.withLock { $0.count } == 1)
            try await provider.trim(dbQueue: fixture.queue, capacity: 1)
            try await fixture.queue.read { db throws in
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM vaults") == "before")
                #expect(try SyncTransactionQueue.hasPending(vaultId: fixture.vaultId, in: db))
                #expect(try String.fetchOne(
                    db,
                    sql: "SELECT text FROM transcript_segment_bodies WHERE segmentId = ?",
                    arguments: [fixture.segmentId]
                ) == "local recording")
                #expect(try TextContentAccess.fileText(fileId: fileId, in: db)?.caption == "Server caption during recording")
            }
            // A stale response must not roll back the synchronized result; it asks sync to read again.
            #expect(try await RemoteChangeApplier.applyIncremental(
                .init(sequence: 1, entity: .file, entityId: fileId, action: "upsert", revision: 1, record: record),
                context: context, dbQueue: fixture.queue
            ) == .retry)
            try await fixture.queue.read { db throws in
                #expect(try Int.fetchOne(db, sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'file'") == 2)
                #expect(try TextContentAccess.availability(entity: .file, id: fileId, in: db).state == .ready)
            }
        }

        @Test
        func anotherMeetingsTranscriptCanHydrateWhileRecordingAndSending() async throws {
            let fixture = try textFixture()
            let recording = UUID.v7()
            try await fixture.queue.write { db in
                try MeetingRecord(id: recording, vaultId: fixture.vaultId, projectId: nil, name: "Recording", createdAt: .now, updatedAt: .now)
                    .insert(db)
                try RecordingSessionRecord(
                    id: .v7(),
                    meetingId: recording,
                    startedAt: .now,
                    endedAt: nil,
                    duration: nil,
                    offsetSeconds: 0,
                    createdAt: .now,
                    updatedAt: .now
                ).insert(db)
                let segment = TranscriptContent(id: .v7(), meetingId: recording, startTime: .now, text: "durable recording", isConfirmed: true)
                try segment.insert(db)
                let patch = SyncOperationDraft(entity: .transcript, action: .patch, entityId: recording)
                try SyncTransactionRecorder.record(
                    vaultId: fixture.vaultId,
                    operations: [patch],
                    transcriptSegments: [patch.id: [.init(segment)]],
                    in: db
                )
            }
            let provider = provider(fixture) { fixture.response($0) }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue)
            try await provider.trim(dbQueue: fixture.queue, capacity: 1)
            try await fixture.queue.read { db throws in
                #expect(try TextContentAccess.transcript(meetingId: fixture.meetingId, in: db).count == 2)
                #expect(try TextContentAccess.transcript(meetingId: recording, in: db).first?.text == "durable recording")
                #expect(try SyncTransactionQueue.hasPending(vaultId: fixture.vaultId, in: db))
            }
        }

        @Test
        func checkedReadersRejectMissingBodiesWithoutCallerPreconditions() throws {
            let (queue, vaultId, meetingId) = try database()
            let segmentId = UUID.v7()
            let fileId = UUID.v7()
            try queue.write { db in
                try TranscriptContent(
                    id: segmentId, meetingId: meetingId, startTime: .now, text: "original",
                    translatedText: "translation", isConfirmed: true, audioFeatureVersion: 1, audioVoicedFrameRatio: 0.7
                ).insert(db)
                try SummaryContent(meetingId: meetingId, title: "Header", document: "{}", createdAt: .now).insert(db)
                try MeetingNoteRecord(meetingId: meetingId, text: "user note", createdAt: .now, updatedAt: .now).insert(db)
                try SummaryExportRecord.setURL("vault:///saved.md", meetingId: meetingId, type: .vault, in: db)
                try FileRecord(
                    id: fileId, vaultId: vaultId, size: 0, contentType: "image/png",
                    checksum: "SHA-256:" + String(repeating: "0", count: 64), name: "image",
                    metadata: .init(source: .screenshot, width: 100, height: 200), createdAt: .now, updatedAt: .now,
                    localReference: "retained local reference"
                ).insert(db)
                try FileTextBodyRecord(fileId: fileId, ocrText: nil, caption: nil).insert(db)
                for (entity, id) in [(TextContentEntity.transcript, meetingId), (.summary, meetingId), (.file, fileId)] {
                    try TextContentStore.registerLocal(entity: entity, id: id, vaultId: vaultId, in: db)
                }
                // A fetched file whose fields are both NULL is different from an absent body row.
                #expect(try TextContentAccess.fileText(fileId: fileId, in: db) != nil)
                #expect(try TextContentAccess.fileText(fileId: fileId, in: db)?.ocrText == nil)
                #expect(try TextContentAccess.transcript(meetingId: meetingId, limit: 1, in: db).first?.text == "original")
                #expect(try TextContentAccess.summary(meetingId: meetingId, in: db)?.document == "{}")
                try db.execute(sql: "DELETE FROM transcript_segment_bodies")
                try db.execute(sql: "DELETE FROM summary_bodies")
                try db.execute(sql: "DELETE FROM file_text_bodies")
                // Even an inconsistent state row must not let an INNER JOIN silently return an empty transcript.
                try db.execute(sql: "UPDATE sync_content_state SET complete = 1")
                #expect(throws: TextContentError.incomplete) { try TextContentAccess.transcript(meetingId: meetingId, in: db) }
                #expect(throws: TextContentError.incomplete) { try TextContentAccess.transcript(meetingId: meetingId, limit: 1, in: db) }
                #expect(throws: TextContentError.incomplete) { try TextContentAccess.summary(meetingId: meetingId, in: db) }
                #expect(throws: TextContentError.incomplete) { try TextContentAccess.fileText(fileId: fileId, in: db) }
                let segment = try #require(try TranscriptSegmentRecord.fetchOne(db, key: segmentId))
                #expect(segment.translatedText == "translation")
                #expect(segment.audioVoicedFrameRatio == 0.7)
                #expect(try SummaryRecord.fetchOne(db, key: meetingId)?.title == "Header")
                #expect(try FileRecord.fetchOne(db, key: fileId)?.localReference == "retained local reference")
                #expect(try MeetingNoteRecord.fetchOne(db, key: meetingId)?.text == "user note")
                #expect(try SummaryExportRecord.fetchOne(meetingId: meetingId, type: .vault, in: db)?.url == "vault:///saved.md")
                #expect(try TextContentAccess.cachedSummary(meetingId: meetingId, in: db) == nil)
            }
        }

        @Test
        func screenshotReadsResolveNonresidentSummaryReferencesOutsideSQLite() throws {
            let fixture = try Fixture()
            let vaultId = fixture.primaryVaultID
            let meetingId = fixture.firstMeetingID
            let screenshotId = fixture.firstScreenshotID
            let response = try JSONEncoder().encode(fixture.store(vaultID: vaultId).meeting(id: meetingId))
            try fixture.manager.dbQueue.write { db in
                let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://references.invalid", clientID: "test", createdAt: .now)
                try connection.insert(db)
                try db.execute(
                    sql: "UPDATE vaults SET accountConnectionId = ?, syncConfirmedConnectionId = ? WHERE id = ?",
                    arguments: [connection.id, connection.id, vaultId]
                )
                try db.execute(
                    sql: "INSERT INTO sync_content_state(vaultId, entity, entityId) VALUES (?, 'summary', ?)",
                    arguments: [vaultId, meetingId]
                )
                try db.execute(sql: "DELETE FROM summary_bodies WHERE meetingId = ?", arguments: [meetingId])
            }
            let calls = Mutex(0)
            let store = try MeetingAccessStore(databaseURL: fixture.databaseURL, vaultID: vaultId, textResolver: { requestedVault, request in
                #expect(requestedVault == vaultId)
                #expect(request.operation == .meeting)
                #expect(request.meetingId == meetingId)
                calls.withLock { $0 += 1 }
                // Return the leased broker result without installing a local body, as if it were evicted immediately after IPC.
                return response
            })
            let page = try store.screenshots(meetingID: meetingId)
            #expect(page.screenshots.first(where: { $0.id == screenshotId })?.isReferencedInSummary == true)
            let image = try store.screenshot(meetingID: meetingId, screenshotID: screenshotId)
            #expect(image.metadata.isReferencedInSummary)
            #expect(calls.withLock { $0 } == 2)
            #expect(throws: MeetingAccessError.meetingNotFound) { try store.screenshots(meetingID: fixture.otherVaultMeetingID) }
            #expect(calls.withLock { $0 } == 2)
        }

        @Test
        func deletingTranscriptMetadataKeepsCompleteBodyAccounting() throws {
            let (queue, vaultId, meetingId) = try database()
            let segment = TranscriptContent(id: .v7(), meetingId: meetingId, startTime: .now, text: "日本語", isConfirmed: true)
            try queue.write { db in
                try segment.insert(db)
                try TextContentStore.registerLocal(entity: .transcript, id: meetingId, vaultId: vaultId, in: db)
                try db.execute(sql: "UPDATE sync_content_state SET verifiedHash = 'verified'")
                try TranscriptSegmentRecord.updateTranslatedText("translation", id: segment.id, in: db)
                #expect(try String.fetchOne(db, sql: "SELECT verifiedHash FROM sync_content_state") == "verified")
                try db.execute(
                    sql: "INSERT INTO transcript_segment_bodies(segmentId, text) VALUES (?, 'next') ON CONFLICT(segmentId) DO UPDATE SET text = excluded.text",
                    arguments: [segment.id]
                )
                #expect(try Int.fetchOne(db, sql: "SELECT byteCount FROM sync_content_state") == 4)
                _ = try TranscriptSegmentRecord.deleteOne(db, key: segment.id)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM transcript_segment_bodies") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT byteCount FROM sync_content_state") == 0)
                #expect(try TextContentAccess.transcript(meetingId: meetingId, in: db).isEmpty)
            }
        }

        @Test
        func newBodiesReplaceKnownEmptyAvailability() throws {
            let (queue, vaultId, meetingId) = try database()
            try queue.write { db in
                for entity in ["summary", "transcript"] {
                    try db.execute(sql: """
                    INSERT INTO sync_content_state(vaultId, entity, entityId, complete, present, contentCount)
                    VALUES (?, ?, ?, 1, 0, 0)
                    """, arguments: [vaultId, entity, meetingId])
                }
                try SummaryContent(meetingId: meetingId, title: "New", document: "{}", createdAt: .now).save(db)
                try TranscriptContent(id: .v7(), meetingId: meetingId, startTime: .now, text: "new", isConfirmed: true).insert(db)
                #expect(try TextContentAccess.availability(entity: .summary, id: meetingId, in: db).state == .ready)
                #expect(try TextContentAccess.availability(entity: .transcript, id: meetingId, in: db).state == .ready)
                #expect(try TextContentAccess.summary(meetingId: meetingId, in: db)?.document == "{}")
                #expect(try TextContentAccess.transcript(meetingId: meetingId, in: db).first?.text == "new")
            }
        }

        @Test
        func completeCachedTextCanBeReadOfflineAndEvictionPreservesLocalData() async throws {
            let (queue, vaultId, meetingId) = try database()
            try await queue.write { db in
                try TranscriptContent(
                    id: .v7(), meetingId: meetingId, startTime: Date(),
                    text: String(repeating: "日本語", count: 100), translatedText: "translation",
                    isConfirmed: true, audioFeatureVersion: 1, audioVoicedFrameRatio: 0.7
                ).insert(db)
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'transcript', ?, 3)", arguments: [vaultId, meetingId])
                try db.execute(
                    sql: "INSERT INTO sync_content_state(vaultId, entity, entityId, residentRevision, complete) VALUES (?, 'transcript', ?, 3, 1)",
                    arguments: [vaultId, meetingId]
                )
                let fingerprint = try #require(try TextContentStore.fingerprint(entity: .transcript, id: meetingId, in: db))
                try db.execute(sql: "UPDATE sync_content_state SET verifiedHash = ?, byteCount = ?", arguments: [fingerprint.hash, fingerprint.bytes])
            }
            let provider = MeetingContentProvider()
            try await provider.ensure(entity: .transcript, id: meetingId, dbQueue: queue)
            await provider.retain(entity: .transcript, id: meetingId, dbQueue: queue)
            try await provider.trim(dbQueue: queue, capacity: 1)
            #expect(try MeetingRepository(dbQueue: queue).fetchSegments(forMeetingId: meetingId).count == 1)
            await provider.release(entity: .transcript, id: meetingId, dbQueue: queue)
            try await provider.trim(dbQueue: queue, capacity: 1)
            try await queue.read { db in
                let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM transcript_segments WHERE meetingId = ?", arguments: [meetingId]))
                #expect(try Int.fetchOne(db, sql: """
                SELECT count(*) FROM transcript_segment_bodies b
                JOIN transcript_segments t ON t.id = b.segmentId WHERE t.meetingId = ?
                """, arguments: [meetingId]) == 0)
                #expect(row["translatedText"] as String? == "translation")
                #expect(row["audioVoicedFrameRatio"] as Double? == 0.7)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions") == 0)
                #expect(try TextContentAccess.availability(entity: .transcript, id: meetingId, in: db).state == .missing)
            }
        }

        @Test
        func swiftAndServerUseIdenticalHashFraming() throws {
            struct Fixture: Decodable {
                struct Field: Decodable { let value: String?
                    let body: Bool
                }

                let fields: [Field]
                let sha256: String
                let byteCount: Int
            }
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let fixtures = try JSONDecoder().decode(
                [Fixture].self,
                from: Data(contentsOf: root.appendingPathComponent("test-fixtures/text-content-v1.json"))
            )
            #expect(fixtures.count == 4)
            for fixture in fixtures {
                var digest = TextContentDigest()
                for field in fixture.fields {
                    digest.add(field.value, body: field.body)
                }
                #expect(digest.digestHex() == fixture.sha256)
                #expect(digest.byteCount == fixture.byteCount)
            }
        }

        @Test
        func pagedHydrationEvictionAndRefetchPreserveHashAndLocalAttributes() async throws {
            let fixture = try textFixture()
            let calls = Mutex(0)
            let provider = provider(fixture) { request in
                calls.withLock { $0 += 1 }
                return fixture.response(request)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue)
            #expect(calls.withLock { $0 } == 3)
            let fingerprint = try await fixture.queue
                .read { try TextContentStore.fingerprint(entity: .transcript, id: fixture.meetingId, in: $0)?.hash }
            #expect(fingerprint == fixture.hash)
            #expect(try MeetingRepository(dbQueue: fixture.queue).fetchSegments(forMeetingId: fixture.meetingId).count == 2)
            try await provider.trim(dbQueue: fixture.queue, capacity: 1)
            #expect(try await MeetingContentProvider.usedBytes(dbQueue: fixture.queue) == 0)
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue)
            #expect(calls.withLock { $0 } == 6)
            try await fixture.queue.read { db throws in
                #expect(try TextContentStore.fingerprint(entity: .transcript, id: fixture.meetingId, in: db)?.hash == fixture.hash)
                #expect(try String
                    .fetchOne(db, sql: "SELECT translatedText FROM transcript_segments WHERE id = ?", arguments: [fixture.segmentId]) ==
                    "local translation")
                #expect(try Double.fetchOne(
                    db,
                    sql: "SELECT audioVoicedFrameRatio FROM transcript_segments WHERE id = ?",
                    arguments: [fixture.segmentId]
                ) == 0.75)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_remote_transcript_items") == 0)
            }
            ImageURLProtocol.remove(origin: fixture.origin)
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue)
        }

        @Test(arguments: ["revision", "delete", "role", "signout", "queue", "failure", "hash"])
        func interruptedDownloadNeverInstallsPartialText(change: String) async throws {
            let fixture = try textFixture()
            let provider = provider(fixture) { request in
                if URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "cursor" }) == true {
                    do {
                        try fixture.queue.write { db in
                            switch change {
                            case "revision": try db.execute(sql: "UPDATE sync_entity_state SET confirmedRevision = 4 WHERE entity = 'transcript'")
                            case "delete": try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [fixture.meetingId])
                            case "role": try db.execute(sql: "UPDATE vaults SET syncRole = 'member' WHERE id = ?", arguments: [fixture.vaultId])
                            case "signout": try db.execute(
                                    sql: "UPDATE vaults SET accountConnectionId = NULL WHERE id = ?",
                                    arguments: [fixture.vaultId]
                                )
                            case "queue":
                                try db.execute(
                                    sql: "INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt) SELECT ?, id, accountConnectionId, ?, ? FROM vaults WHERE id = ?",
                                    arguments: [UUID.v7(), Date(), Date(), fixture.vaultId]
                                )
                            default: break
                            }
                        }
                    } catch { return (500, [:], Data()) }
                    if change == "failure" { return (503, [:], Data()) }
                    if change == "hash" { return (200, [:], fixture.secondPageCorrupt) }
                }
                return fixture.response(request)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            await #expect(throws: (any Error).self) {
                try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue)
            }
            try await fixture.queue.read { db throws in
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM transcript_segment_bodies") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_content_state WHERE entity = 'transcript' AND complete = 1") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_remote_transcript_items") == 0)
                if change == "delete" { #expect(try MeetingRecord.fetchOne(db, key: fixture.meetingId) == nil) }
            }
        }

        @Test(arguments: [false, true])
        func discardingNewSummaryPreservesOnlyTheInitialUploadSource(hasConfirmedVault: Bool) async throws {
            let (queue, vaultId, meetingId) = try database()
            try await queue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_content_state(vaultId, entity, entityId, residentRevision, complete, present) VALUES (?, 'summary', ?, 0, 1, 0)",
                    arguments: [vaultId, meetingId]
                )
                if hasConfirmedVault {
                    try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'vault', ?, 1)", arguments: [vaultId, vaultId])
                }
            }
            let document = try SummaryDocument(title: "New local summary", sections: []).databaseJSONString()
            try MeetingRepository(dbQueue: queue).applyGeneratedSummary(
                toMeetingId: meetingId, document: SummaryDocument(title: "New local summary", sections: []), tags: []
            )
            let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: queue))
            try await SyncTransactionQueue.block(transaction, reason: .validation, response: Data("{}".utf8), dbQueue: queue)
            try await SyncTransactionQueue.discardInvalidTransaction(vaultId: vaultId, dbQueue: queue)
            try await queue.read { db in
                #expect(try String
                    .fetchOne(db, sql: "SELECT document FROM summary_bodies WHERE meetingId = ?", arguments: [meetingId]) ==
                    (hasConfirmedVault ? nil : document))
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM summaries WHERE meetingId = ?", arguments: [meetingId]) == 1)
                if hasConfirmedVault {
                    #expect(throws: TextContentError.incomplete) { try TextContentAccess.requireComplete(entity: .summary, id: meetingId, in: db) }
                } else {
                    try TextContentAccess.requireComplete(entity: .summary, id: meetingId, in: db)
                    #expect(try SyncTransactionQueue.hasPending(vaultId: vaultId, in: db))
                }
            }
        }

        @Test(arguments: [TextContentEntity.summary, .transcript], [SyncBlockedReason.conflict, .validation])
        func abandoningLocalBodyRefetchesUnchangedCanonicalRevision(entity: TextContentEntity, reason: SyncBlockedReason) async throws {
            let fixture = try textFixture()
            let document = try SummaryDocument(title: "Canonical", sections: []).databaseJSONString()
            var digest = TextContentDigest()
            digest.add(document)
            let manifest: [String: Any] = [
                "version": 1, "entity": "summary", "entityId": fixture.meetingId.uuidString,
                "revision": 3, "present": true, "count": 1, "byteCount": digest.byteCount, "sha256": digest.digestHex(),
            ]
            var body = manifest
            body["record"] = ["title": "Canonical", "document": document, "createdAt": "2026-01-01T00:00:00.000Z"]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest)
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            let provider = provider(fixture) { request in
                if request.url!.path.contains("/summary/") {
                    return (200, [:], (request.url!.query ?? "").contains("manifest") ? manifestData : bodyData)
                }
                return fixture.response(request)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue)
            try await fixture.queue.write { db in
                try SummaryContent(meetingId: fixture.meetingId, title: "Canonical", document: document, createdAt: .now).insert(db)
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'summary', ?, 3)", arguments: [fixture.vaultId, fixture.meetingId])
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'vault', ?, 2)", arguments: [fixture.vaultId, fixture.vaultId])
                try db.execute(sql: "UPDATE vaults SET syncPullCursor = 'ready'")
                try TextContentStore.registerLocal(entity: .summary, id: fixture.meetingId, vaultId: fixture.vaultId, in: db)
            }
            let expectedHash = entity == .summary ? digest.digestHex() : fixture.hash
            if entity == .summary {
                try MeetingRepository(dbQueue: fixture.queue).applyGeneratedSummary(
                    toMeetingId: fixture.meetingId, document: SummaryDocument(title: "Discarded local", sections: []), tags: []
                )
            } else {
                try await fixture.queue.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO transcript_segment_bodies(segmentId, text)
                        SELECT id, 'Discarded local'
                        FROM transcript_segments
                        WHERE id = ?
                        ON CONFLICT(segmentId) DO UPDATE SET text = excluded.text
                        """,
                        arguments: [fixture.segmentId]
                    )
                    let segment = try #require(try fetchTranscriptContent(id: fixture.segmentId, in: db))
                    let patch = SyncOperationDraft(entity: .transcript, action: .patch, entityId: fixture.meetingId)
                    try SyncTransactionRecorder.record(vaultId: fixture.vaultId, operations: [
                        SyncOperationDraft(entity: .meeting, action: .update, entityId: fixture.meetingId), patch,
                    ], transcriptSegments: [patch.id: [SyncTranscriptPatchSegment(segment)]], in: db)
                }
            }
            let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
            try await SyncTransactionQueue.block(transaction, reason: reason, response: Data("{}".utf8), dbQueue: fixture.queue)
            if reason == .conflict {
                try await SyncTransactionQueue.acceptServerVersion(vaultId: fixture.vaultId, dbQueue: fixture.queue)
            } else {
                try await SyncTransactionQueue.discardInvalidTransaction(vaultId: fixture.vaultId, dbQueue: fixture.queue)
            }
            try await fixture.queue.read { db in
                #expect(throws: TextContentError.incomplete) {
                    try TextContentAccess.requireComplete(entity: entity, id: fixture.meetingId, in: db)
                }
                let unaffected: TextContentEntity = entity == .summary ? .transcript : .summary
                try TextContentAccess.requireComplete(entity: unaffected, id: fixture.meetingId, in: db)
            }
            let metadata = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: JSONSerialization.data(withJSONObject: [
                "contentOmitted": true, "contentPresent": true, "contentCount": entity == .transcript ? 2 : 1,
                "title": "Canonical", "createdAt": "2026-01-01T00:00:00.000Z",
            ]))
            let connectionId = try #require(try await fixture.queue.read { try VaultRecord.fetchOne($0, key: fixture.vaultId)?.accountConnectionId })
            #expect(try await RemoteChangeApplier.apply(
                [
                    .init(
                        sequence: 4,
                        entity: #require(SyncEntity(rawValue: entity.rawValue)),
                        entityId: fixture.meetingId,
                        action: "upsert",
                        revision: 3,
                        record: metadata
                    ),
                ],
                screenshots: [:],
                transcripts: [:],
                cursor: "after-reset",
                vaultId: fixture.vaultId,
                expectedConnectionId: connectionId,
                dbQueue: fixture.queue
            ))
            // Even a failed attempt must not make the intentionally discarded body readable again.
            ImageURLProtocol.register(origin: fixture.origin) { _ in (503, [:], Data()) }
            await #expect(throws: TextContentError.unavailable) {
                try await provider.ensure(entity: entity, id: fixture.meetingId, dbQueue: fixture.queue)
            }
            ImageURLProtocol.register(origin: fixture.origin) { request in
                if entity == .summary { return (200, [:], (request.url!.query ?? "").contains("manifest") ? manifestData : bodyData) }
                return fixture.response(request)
            }
            try await provider.ensure(entity: entity, id: fixture.meetingId, dbQueue: fixture.queue)
            #expect(try await fixture.queue
                .read { try TextContentStore.fingerprint(entity: entity, id: fixture.meetingId, in: $0)?.hash } == expectedHash)
            #expect(try await fixture.queue.read { try TextContentAccess.availability(entity: entity, id: fixture.meetingId, in: $0).revision } == 3)
        }

        @Test
        func matchingTextHashStillRefreshesCanonicalTranscriptHeaders() async throws {
            let fixture = try textFixture()
            let provider = provider(fixture, handler: fixture.response)
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue)
            let responses = try [fixture.manifest, fixture.firstPage, fixture.secondPage].enumerated().map { index, data in
                var value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                value["revision"] = 4
                if index == 1 {
                    var items = try #require(value["items"] as? [[String: Any]])
                    items[0]["startTime"] = "2026-01-01T00:00:00.100Z"
                    items[0]["endTime"] = "2026-01-01T00:00:00.500Z"
                    items[0]["audioSource"] = "mic"
                    items[0]["speakerLabel"] = "Updated speaker"
                    value["items"] = items
                }
                return try JSONSerialization.data(withJSONObject: value)
            }
            let calls = Mutex(0)
            ImageURLProtocol.register(origin: fixture.origin) { request in
                calls.withLock { $0 += 1 }
                let query = request.url!.query!
                return (200, [:], responses[query.contains("manifest") ? 0 : query.contains("cursor") ? 2 : 1])
            }
            try await fixture.queue.write { db in
                try db.execute(sql: "UPDATE sync_entity_state SET confirmedRevision = 4 WHERE entity = 'transcript'")
            }
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue, refresh: true)
            #expect(calls.withLock { $0 } == 3)
            try await fixture.queue.read { db in
                let segment = try #require(try fetchTranscriptContent(id: fixture.segmentId, in: db))
                #expect(abs(segment.startTime.timeIntervalSince1970 - 1_767_225_600.1) < 0.001)
                #expect(segment.endTime == Date(timeIntervalSince1970: 1_767_225_600.5))
                #expect(segment.audioSource == "mic")
                #expect(segment.speakerLabel == "Updated speaker")
                #expect(segment.translatedText == "local translation")
                #expect(try TextContentStore.fingerprint(entity: .transcript, id: fixture.meetingId, in: db)?.hash == fixture.hash)
                #expect(try TextContentAccess.availability(entity: .transcript, id: fixture.meetingId, in: db).revision == 4)
            }
        }

        @Test(arguments: [false, true])
        func conversationMetricsRejectUnretainedOriginals(hasRetainedRows: Bool) async throws {
            let fixture = try textFixture()
            try await fixture.queue.write { db in
                if hasRetainedRows {
                    try db.execute(sql: "UPDATE transcript_segments SET audioSource = 'mic'")
                } else {
                    try db.execute(sql: "DELETE FROM transcript_segments")
                }
            }
            #expect(throws: TextContentError.incomplete) {
                try MeetingRepository(dbQueue: fixture.queue).loadOrRebuildConversationMetrics(meetingId: fixture.meetingId)
            }
            #expect(try await fixture.queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM meeting_conversation_metrics") } == 0)
            let provider = provider(fixture) { _ in (503, [:], Data()) }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let store = MeetingConversationMetricsStore { meetingId, queue in
                try await MeetingConversationMetricsRefreshService.load(meetingId: meetingId, dbQueue: queue, contentProvider: provider)
            }
            await store.load(meetingId: fixture.meetingId, dbQueue: fixture.queue)
            #expect(store.metrics == nil)
            #expect(store.errorMessage != nil)
            #expect(try await fixture.queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM meeting_conversation_metrics") } == 0)
            let pages = try [fixture.firstPage, fixture.secondPage].map { data in
                var page = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                var items = try #require(page["items"] as? [[String: Any]])
                items[0]["audioSource"] = "mic"
                page["items"] = items
                return try JSONSerialization.data(withJSONObject: page)
            }
            ImageURLProtocol.register(origin: fixture.origin) { request in
                let query = request.url!.query!
                return (200, [:], query.contains("manifest") ? fixture.manifest : pages[query.contains("cursor") ? 1 : 0])
            }
            await store.load(meetingId: fixture.meetingId, dbQueue: fixture.queue)
            let metrics = try #require(store.metrics)
            #expect(store.errorMessage == nil)
            #expect(metrics.source(.microphone).segmentCount == 2)
            #expect(metrics.source(.microphone).normalizedCharacterCount > 0)
            try await provider.trim(dbQueue: fixture.queue, capacity: 1)
            let reloaded = try await MeetingConversationMetricsRefreshService.load(
                meetingId: fixture.meetingId, dbQueue: fixture.queue, contentProvider: provider
            )
            #expect(reloaded.inputFingerprint == metrics.inputFingerprint)
            #expect(reloaded.source(.microphone).segmentCount == 2)
        }

        @Test
        func legacyMismatchIsKeptAndCannotBeEvicted() async throws {
            let fixture = try textFixture()
            try await fixture.queue.write { db in
                try db
                    .execute(
                        sql: """
                        INSERT INTO transcript_segment_bodies(segmentId, text)
                        SELECT id, 'unverified local body'
                        FROM transcript_segments
                        WHERE true
                        ON CONFLICT(segmentId) DO UPDATE SET text = excluded.text
                        """
                    )
                try db.execute(sql: "UPDATE sync_content_state SET complete = 1, residentRevision = 3")
            }
            let calls = Mutex(0)
            let provider = provider(fixture) { request in
                calls.withLock { $0 += 1 }
                return fixture.response(request)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            await #expect(throws: TextContentError.integrityFailure) {
                try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue, refresh: true)
            }
            try await provider.trim(dbQueue: fixture.queue, capacity: 1)
            #expect(calls.withLock { $0 } == 1)
            #expect(try MeetingRepository(dbQueue: fixture.queue).fetchSegments(forMeetingId: fixture.meetingId).first?
                .text == "unverified local body")
        }

        @Test
        func budgetRejectsOversizedPrefetchBeforeDownloadingBody() async throws {
            let fixture = try textFixture()
            let calls = Mutex(0)
            let provider = provider(fixture) { request in
                calls.withLock { $0 += 1 }
                return fixture.response(request)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue, prefetchBudget: 1)
            #expect(calls.withLock { $0 } == 1)
            #expect(try await MeetingContentProvider.usedBytes(dbQueue: fixture.queue) == 0)
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue)
            #expect(calls.withLock { $0 } == 4)
        }

        @Test
        func diskStorageIsReclaimedAndReuseStaysBounded() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("text.sqlite").path
            let (queue, vaultId, meetingId) = try database(path: path)
            try await ScreenshotStorageMaintenance.compactAtStartup(dbQueue: queue, minimumFreeBytes: 0)
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'transcript', ?, 3)", arguments: [vaultId, meetingId])
                try db.execute(
                    sql: "INSERT INTO sync_content_state(vaultId, entity, entityId, residentRevision, complete) VALUES (?, 'transcript', ?, 3, 1)",
                    arguments: [vaultId, meetingId]
                )
            }
            let provider = MeetingContentProvider()
            var retainedSizes: [Int] = []
            var trimmedSizes: [Int] = []
            for _ in 0 ..< 2 {
                try await queue.write { db in
                    try db.execute(sql: "DELETE FROM transcript_segments WHERE meetingId = ?", arguments: [meetingId])
                    try db.execute(sql: "UPDATE sync_content_state SET complete = 1")
                    for index in 0 ..< 256 {
                        try TranscriptContent(
                            id: .v7(), meetingId: meetingId, startTime: Date(timeIntervalSince1970: Double(index)),
                            text: String(repeating: "日本語🙂", count: 1024), isConfirmed: true
                        ).insert(db)
                    }
                    let fingerprint = try #require(try TextContentStore.fingerprint(entity: .transcript, id: meetingId, in: db))
                    try db.execute(
                        sql: "UPDATE sync_content_state SET verifiedHash = ?, byteCount = ?",
                        arguments: [fingerprint.hash, fingerprint.bytes]
                    )
                }
                try await queue.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
                try retainedSizes.append(storageBytes(directory))
                try await provider.trim(dbQueue: queue, capacity: 1)
                try await queue.writeWithoutTransaction { db in
                    for _ in 0 ..< 10000 {
                        if try (Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0) == 0 { break }
                        _ = try Row.fetchAll(db, sql: "PRAGMA incremental_vacuum(256)")
                    }
                    try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                }
                try trimmedSizes.append(storageBytes(directory))
                #expect(try await MeetingContentProvider.usedBytes(dbQueue: queue) == 0)
            }
            print("Text retention DB/WAL bytes: retained=\(retainedSizes), trimmed=\(trimmedSizes)")
            #expect(trimmedSizes[0] < retainedSizes[0] / 2)
            #expect(trimmedSizes[1] < retainedSizes[1] / 2)
            #expect(trimmedSizes[1] <= trimmedSizes[0] + 128 * 1024)
        }

        @Test(arguments: ["recording", "pending", "conflict", "local"])
        func durableAndActiveContentIsNeverEvicted(protection: String) async throws {
            let fixture = try textFixture()
            let provider = provider(fixture, handler: fixture.response)
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue)
            try await fixture.queue.write { db in
                switch protection {
                case "recording":
                    try RecordingSessionRecord(
                        id: .v7(),
                        meetingId: fixture.meetingId,
                        startedAt: .now,
                        offsetSeconds: 0,
                        createdAt: .now,
                        updatedAt: .now
                    ).insert(db)
                case "pending":
                    try db.execute(
                        sql: "INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt) SELECT ?, id, accountConnectionId, ?, ? FROM vaults WHERE id = ?",
                        arguments: [UUID.v7(), Date(), Date(), fixture.vaultId]
                    )
                case "conflict": try db.execute(sql: "UPDATE vaults SET syncRecoveryState = 'pending'")
                default: try db.execute(sql: "UPDATE vaults SET accountConnectionId = NULL, syncConfirmedConnectionId = NULL")
                }
            }
            try await provider.trim(dbQueue: fixture.queue, capacity: 1)
            #expect(try MeetingRepository(dbQueue: fixture.queue).fetchSegments(forMeetingId: fixture.meetingId).count == 2)
        }

        @Test
        func tenThousandMetadataRowsPrefetchOnlyTwentyRecentMeetings() async throws {
            let (queue, vaultId, _) = try database()
            let origin = try await queue.read { try #require(try String.fetchOne($0, sql: "SELECT origin FROM dahlia_account_connections")) }
            try await queue.write { db in
                try db.execute(sql: "DELETE FROM meetings")
                try db.execute(sql: "UPDATE vaults SET syncPullCursor = 'ready'")
                for index in 0 ..< 10000 {
                    let id = UUID.v7()
                    try MeetingRecord(
                        id: id,
                        vaultId: vaultId,
                        projectId: nil,
                        name: "Metadata",
                        createdAt: Date(timeIntervalSince1970: Double(index)),
                        updatedAt: .now
                    ).insert(db)
                    try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'transcript', ?, 1)", arguments: [vaultId, id])
                    try db.execute(
                        sql: "INSERT INTO sync_content_state(vaultId, entity, entityId, contentCount) VALUES (?, 'transcript', ?, 1)",
                        arguments: [vaultId, id]
                    )
                }
            }
            let manifests = Mutex(Set<String>())
            ImageURLProtocol.register(origin: origin) { request in
                let id = request.url!.lastPathComponent
                var digest = TextContentDigest()
                digest.add(id, body: false)
                digest.add("recent body")
                var payload: [String: Any] = [
                    "version": 1,
                    "entity": "transcript",
                    "entityId": id,
                    "revision": 1,
                    "present": true,
                    "count": 1,
                    "byteCount": digest.byteCount,
                    "sha256": digest.digestHex(),
                ]
                if (request.url!.query ?? "").contains("manifest") {
                    _ = manifests.withLock { $0.insert(id) }
                } else {
                    payload["items"] = [["segmentId": id, "startTime": "2026-01-01T00:00:00.000Z", "text": "recent body", "isConfirmed": true]]
                }
                do {
                    return try (200, [:], JSONSerialization.data(withJSONObject: payload))
                } catch { return (500, [:], Data()) }
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let provider = MeetingContentProvider(client: SyncAPIClient(
                session: URLSession(configuration: configuration),
                tokenProvider: { _, _ in "test-token" }
            ))
            await provider.scheduleMaintenance(dbQueue: queue)
            await provider.maintenance[ObjectIdentifier(queue)]?.value
            #expect(manifests.withLock { $0.count } == 20)
            #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_content_state WHERE complete = 1") } == 20)
            #expect(try await MeetingContentProvider.usedBytes(dbQueue: queue) == 20 * "recent body".utf8.count)
            await provider.scheduleMaintenance(dbQueue: queue)
            await provider.maintenance[ObjectIdentifier(queue)]?.value
            #expect(manifests.withLock { $0.count } == 20)
        }

        @Test
        func brokerHydratesTranscriptAndRejectsAnotherVault() async throws {
            let fixture = try textFixture()
            let provider = provider(fixture, handler: fixture.response)
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let request = TextBrokerRequest(operation: .transcript, meetingId: fixture.meetingId, limit: 1)
            let first = try await provider.resolve(request, vaultId: fixture.vaultId, dbQueue: fixture.queue)
            let page = try JSONDecoder().decode(TranscriptPage.self, from: first)
            #expect(page.segments.count == 1)
            #expect(page.textContent?.state == .ready)
            await #expect(throws: TextContentError.deleted) {
                try await provider.resolve(request, vaultId: .v7(), dbQueue: fixture.queue)
            }
        }

        @Test
        func serverSearchValidatesTheSameLengthForUIAndBroker() async throws {
            let fixture = try textFixture()
            let queries = Mutex<[String]>([])
            let provider = provider(fixture) { request in
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                    .first { $0.name == "q" }!.value!
                queries.withLock { $0.append(query) }
                return (200, [:], Data(#"{"version":1,"scope":"server","items":[],"nextCursor":null}"#.utf8))
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            for (query, accepted) in [
                (String(repeating: "a", count: 500), true),
                (String(repeating: "a", count: 501), false),
                (String(repeating: "🙂", count: 250), true),
                (String(repeating: "🙂", count: 251), false),
                ("  " + String(repeating: "a", count: 500) + "\n", true),
                (" \n", false),
            ] {
                queries.withLock { $0.removeAll() }
                let request = TextBrokerRequest(operation: .search, query: query, kind: .screenshot)
                if accepted {
                    _ = try await provider.search(vaultId: fixture.vaultId, query: query, kind: .meeting, dbQueue: fixture.queue)
                    _ = try await provider.resolve(request, vaultId: fixture.vaultId, dbQueue: fixture.queue)
                    #expect(queries.withLock { $0 } == Array(repeating: query.trimmingCharacters(in: .whitespacesAndNewlines), count: 2))
                } else {
                    await #expect(throws: TextContentError.unavailable) {
                        try await provider.search(vaultId: fixture.vaultId, query: query, kind: .meeting, dbQueue: fixture.queue)
                    }
                    await #expect(throws: TextContentError.unavailable) {
                        try await provider.resolve(request, vaultId: fixture.vaultId, dbQueue: fixture.queue)
                    }
                    #expect(queries.withLock { $0.isEmpty })
                }
            }
        }

        @Test
        func serverSearchContinuesAfterFilteredPageWithoutHydratingText() async throws {
            let fixture = try textFixture()
            let includedId = UUID.v7()
            try await fixture.queue.write { db in
                try db.execute(sql: "UPDATE meetings SET createdAt = ?", arguments: [Date(timeIntervalSince1970: 100)])
                try MeetingRecord(
                    id: includedId,
                    vaultId: fixture.vaultId,
                    projectId: nil,
                    name: "Unretained hit",
                    createdAt: Date(timeIntervalSince1970: 1000),
                    updatedAt: .now
                ).insert(db)
            }
            let calls = Mutex(0)
            let provider = provider(fixture) { request in
                calls.withLock { $0 += 1 }
                let next = request.url!.query!.contains("cursor=")
                let id = next ? includedId : fixture.meetingId
                let body: [String: Any] = [
                    "version": 1,
                    "scope": "server",
                    "items": [["id": id.uuidString, "meetingId": id.uuidString, "snippet": "Server-only match"]],
                    "nextCursor": next ? NSNull() : "next",
                ]
                do {
                    return try (200, [:], JSONSerialization.data(withJSONObject: body))
                } catch { return (500, [:], Data()) }
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let page = try await MeetingRepository.remoteMeetingPage(
                vaultId: fixture.vaultId,
                criteria: .init(text: "match", startDate: Date(timeIntervalSince1970: 500)),
                cursor: nil,
                dbQueue: fixture.queue,
                contentProvider: provider
            )
            #expect(page.items.map(\.id) == [includedId])
            #expect(page.cursor == nil)
            #expect(calls.withLock { $0 } == 2)
            #expect(try await MeetingContentProvider.usedBytes(dbQueue: fixture.queue) == 0)
        }

        @Test
        func mcpServerMeetingSearchAppliesFiltersBeforeFinishingPages() throws {
            let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let databaseURL = root.appendingPathComponent("test.sqlite")
            let (queue, vaultId, excludedId) = try database(path: databaseURL.path)
            let includedId = UUID.v7()
            try queue.write { db in
                try db.execute(sql: "UPDATE meetings SET createdAt = ?", arguments: [Date(timeIntervalSince1970: 100)])
                try MeetingRecord(
                    id: includedId, vaultId: vaultId, projectId: nil, name: "Retained metadata",
                    createdAt: Date(timeIntervalSince1970: 1000), updatedAt: .now
                ).insert(db)
                try db.execute(sql: "UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'fts'")
            }
            func page(id: UUID, next: String?) throws -> Data {
                try JSONSerialization.data(withJSONObject: [
                    "version": 1, "scope": "server",
                    "items": [["id": id.uuidString, "meetingId": id.uuidString, "snippet": "remote match"]],
                    "nextCursor": next as Any? ?? NSNull(),
                ])
            }
            let first = try page(id: excludedId, next: "next")
            let second = try page(id: includedId, next: nil)
            let cursors = Mutex<[String?]>([])
            let store = try MeetingAccessStore(databaseURL: databaseURL, vaultID: vaultId, textResolver: { _, request in
                cursors.withLock { $0.append(request.cursor) }
                return request.cursor == nil ? first : second
            })
            let result = try store.queryMeetings(.init(query: "remote", createdFrom: Date(timeIntervalSince1970: 500), limit: 1))
            #expect(result.server?.items.map(\.meetingId) == [includedId])
            #expect(result.server?.complete == true)
            #expect(result.server?.error == nil)
            #expect(cursors.withLock { $0 } == [nil, "next"])
        }

        @Test
        func bodyEditsKeepResidentRevisionWhileExplicitReapplyUsesLatest() async throws {
            let fixture = try textFixture()
            try await fixture.queue.write { db in
                try db
                    .execute(
                        sql: """
                        INSERT INTO transcript_segment_bodies(segmentId, text)
                        SELECT id, 'resident'
                        FROM transcript_segments
                        WHERE true
                        ON CONFLICT(segmentId) DO UPDATE SET text = excluded.text
                        """
                    )
                try db.execute(sql: "UPDATE sync_content_state SET complete = 1, residentRevision = 2")
                let segment = try SyncTranscriptPatchSegment(#require(try fetchTranscriptContent(id: fixture.segmentId, in: db)))
                let operation = SyncOperationDraft(entity: .transcript, action: .patch, entityId: fixture.meetingId)
                try SyncTransactionRecorder.record(
                    vaultId: fixture.vaultId,
                    operations: [operation],
                    transcriptSegments: [operation.id: [segment]],
                    in: db
                )
                #expect(try Int.fetchOne(db, sql: "SELECT baseRevision FROM sync_operations") == 2)
                try SyncTransactionQueue.discard(vaultId: fixture.vaultId, in: db)
                try SyncTransactionRecorder.record(
                    vaultId: fixture.vaultId,
                    operations: [operation],
                    transcriptSegments: [operation.id: [segment]],
                    reapplyOnCurrentRevision: true,
                    in: db
                )
                #expect(try Int.fetchOne(db, sql: "SELECT baseRevision FROM sync_operations") == 3)
                #expect(try Int.fetchOne(db, sql: "SELECT residentRevision FROM sync_content_state") == 2)
            }
        }

        @Test
        func rebasedTranscriptReceiptRequiresCanonicalBodyRefresh() async throws {
            let fixture = try textFixture()
            try await fixture.queue.write { db in
                try db
                    .execute(
                        sql: """
                        INSERT INTO transcript_segment_bodies(segmentId, text)
                        SELECT id, 'first 日本語'
                        FROM transcript_segments
                        WHERE true
                        ON CONFLICT(segmentId) DO UPDATE SET text = excluded.text
                        """
                    )
                try db.execute(sql: "UPDATE sync_content_state SET complete = 1, residentRevision = 1")
                try db.execute(sql: "UPDATE sync_entity_state SET confirmedRevision = 2")
                let segment = try SyncTranscriptPatchSegment(#require(try fetchTranscriptContent(id: fixture.segmentId, in: db)))
                let operation = SyncOperationDraft(entity: .transcript, action: .patch, entityId: fixture.meetingId)
                try SyncTransactionRecorder.record(
                    vaultId: fixture.vaultId, operations: [operation], transcriptSegments: [operation.id: [segment]],
                    reapplyOnCurrentRevision: true, in: db
                )
            }
            let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
            #expect(transaction.operations.first?.baseRevision == 2)
            try await SyncTransactionQueue.complete(transaction, response: .init(
                id: transaction.id, status: "committed", cursor: "receipt",
                records: [.init(entity: .transcript, id: fixture.meetingId, revision: 3, record: nil)]
            ), dbQueue: fixture.queue)
            let state = try await fixture.queue.read { try TextContentAccess.availability(entity: .transcript, id: fixture.meetingId, in: $0) }
            #expect(state.state == .stale)
            #expect(state.revision == 1)
            let provider = provider(fixture, handler: fixture.response)
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue, refresh: true)
            #expect(try MeetingRepository(dbQueue: fixture.queue).fetchSegments(forMeetingId: fixture.meetingId).count == 2)
            #expect(try await fixture.queue
                .read { try TextContentStore.fingerprint(entity: .transcript, id: fixture.meetingId, in: $0)?.hash } == fixture.hash)
        }

        @Test
        func sequentialTranscriptReceiptsAdvanceTheCompleteLocalBase() async throws {
            let fixture = try textFixture()
            try await fixture.queue.write { db in
                try db
                    .execute(
                        sql: """
                        INSERT INTO transcript_segment_bodies(segmentId, text)
                        SELECT id, 'first 日本語'
                        FROM transcript_segments
                        WHERE true
                        ON CONFLICT(segmentId) DO UPDATE SET text = excluded.text
                        """
                    )
                try db.execute(sql: "UPDATE sync_content_state SET complete = 1, residentRevision = 1")
                try db.execute(sql: "UPDATE sync_entity_state SET confirmedRevision = 1")
                let segment = try SyncTranscriptPatchSegment(#require(try fetchTranscriptContent(id: fixture.segmentId, in: db)))
                for _ in 0 ..< 2 {
                    let operation = SyncOperationDraft(entity: .transcript, action: .patch, entityId: fixture.meetingId)
                    try SyncTransactionRecorder.record(
                        vaultId: fixture.vaultId, operations: [operation], transcriptSegments: [operation.id: [segment]], in: db
                    )
                }
            }
            for revision in 2 ... 3 {
                let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.queue))
                #expect(transaction.operations.first?.baseRevision == revision - 1)
                try await SyncTransactionQueue.complete(transaction, response: .init(
                    id: transaction.id, status: "committed", cursor: "receipt",
                    records: [.init(entity: .transcript, id: fixture.meetingId, revision: revision, record: nil)]
                ), dbQueue: fixture.queue)
                let state = try await fixture.queue.read { try TextContentAccess.availability(entity: .transcript, id: fixture.meetingId, in: $0) }
                #expect(state.state == .ready)
                #expect(state.revision == revision)
            }
        }

        @Test
        func maximumAcceptedTranscriptChunkCanBeReadWithItsResponseEnvelope() async throws {
            let fixture = try textFixture()
            let maximumChunkBytes = 8 * 1024 * 1024
            var item: [String: Any] = [
                "segmentId": fixture.segmentId.uuidString.lowercased(), "startTime": "2026-01-01T00:00:00.000Z",
                "text": "", "isConfirmed": true,
                "endTime": NSNull(), "audioSource": NSNull(), "speakerLabel": NSNull(),
            ]
            let overhead = try JSONSerialization.data(withJSONObject: ["segments": [item], "deletions": []]).count
            let text = String(repeating: "a", count: maximumChunkBytes - overhead)
            item["text"] = text
            #expect(try JSONSerialization.data(withJSONObject: ["segments": [item], "deletions": []]).count == maximumChunkBytes)
            var digest = TextContentDigest()
            digest.add(fixture.segmentId.uuidString.lowercased(), body: false)
            digest.add(text)
            let manifest: [String: Any] = [
                "version": 1, "entity": "transcript", "entityId": fixture.meetingId.uuidString, "revision": 3,
                "present": true, "count": 1, "byteCount": digest.byteCount, "sha256": digest.digestHex(),
            ]
            var page = manifest
            page["items"] = [item]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest)
            let pageData = try JSONSerialization.data(withJSONObject: page)
            #expect(pageData.count > maximumChunkBytes)
            let provider = provider(fixture) { request in
                (200, [:], (request.url!.query ?? "").contains("manifest") ? manifestData : pageData)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue)
            let expectedHash = digest.digestHex()
            #expect(try await fixture.queue
                .read { try TextContentStore.fingerprint(entity: .transcript, id: fixture.meetingId, in: $0)?.hash } == expectedHash)
        }

        @Test
        func concurrentReadsShareRequestsAndUseAtMostTwoSlots() async throws {
            let fixtures = try (0 ..< 3).map { _ in try textFixture() }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            let gate = TextRequestGate()
            let provider = MeetingContentProvider(client: SyncAPIClient(session: URLSession(configuration: configuration), tokenProvider: { _, _ in
                await gate.wait()
                return "test-token"
            }))
            for fixture in fixtures {
                ImageURLProtocol.register(origin: fixture.origin, handler: fixture.response)
            }
            defer { for fixture in fixtures {
                ImageURLProtocol.remove(origin: fixture.origin)
            } }
            let tasks = [fixtures[0], fixtures[0], fixtures[1], fixtures[2]].map { fixture in
                Task { try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue) }
            }
            await gate.waitUntilTwoReadsStart()
            let users = try await Task.detached {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                var users = 0
                repeat {
                    users = await provider.requests.values.reduce(0) { $0 + $1.users.count }
                    if users == 4 { break }
                    try await Task.sleep(for: .milliseconds(5))
                } while ContinuousClock.now < deadline
                return users
            }.value
            #expect(users == 4)
            #expect(await provider.requests.count == 3)
            #expect(await gate.count == 2)
            await gate.open()
            for task in tasks {
                try await task.value
            }
            #expect(await provider.requests.isEmpty)
        }

        @Test(arguments: ["success", "textFailure", "serverChanged", "checkFailed", "localCursorChanged"])
        func localAccountTransferRequiresAllTextAndPreservesConnectionOnFailure(scenario: String) async throws {
            let fail = scenario != "success"
            let changeRequests = Mutex(0)
            let fixture = try textFixture()
            let connectionId = try await fixture.queue.write { db in
                try db.execute(sql: "UPDATE vaults SET syncPullCursor = 'before'")
                return try #require(try UUID.fetchOne(db, sql: "SELECT accountConnectionId FROM vaults"))
            }
            var emptyDigest = TextContentDigest()
            emptyDigest.add(nil)
            let summaryManifest = try JSONSerialization.data(withJSONObject: [
                "version": 1,
                "entity": "summary",
                "entityId": fixture.meetingId.uuidString,
                "revision": 0,
                "present": false,
                "count": 0,
                "byteCount": 0,
                "sha256": emptyDigest.digestHex(),
            ])
            let provider = provider(fixture) { request in
                let path = request.url!.path
                if path.hasSuffix("/capabilities") { return (200, [:], Data("{\"sync\":{\"version\":3}}".utf8)) }
                if path.hasSuffix("/changes") {
                    let count = changeRequests.withLock { $0 += 1
                        return $0
                    }
                    if count == 2 {
                        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                        #expect(query?.first { $0.name == "cursor" }?.value == "after")
                        #expect(query?.contains { $0.name == "highWaterCursor" } == false)
                        if scenario == "checkFailed" { return (503, [:], Data()) }
                        if scenario == "localCursorChanged" {
                            do {
                                try fixture.queue.write { db in
                                    try db.execute(sql: "UPDATE vaults SET syncPullCursor = 'concurrent'")
                                }
                            } catch { Issue.record(error) }
                        }
                    }
                    let cursor = count >= 2 && scenario == "serverChanged" ? "new-server-update" : "after"
                    return (200, [:], Data("""
                    {"items":[],"cursor":"\(cursor)","highWaterCursor":"\(cursor)","hasMore":false}
                    """.utf8))
                }
                if path.contains("/summary/") { return (200, [:], summaryManifest) }
                if scenario == "textFailure" { return (503, [:], Data()) }
                return fixture.response(request)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let repository = MeetingRepository(dbQueue: fixture.queue)
            if fail {
                await #expect(throws: (any Error).self) {
                    try await repository.resolveVaultsForSignOut(connectionID: connectionId, disposition: .moveToLocalAccount, textContent: provider)
                }
            } else {
                try await repository.resolveVaultsForSignOut(connectionID: connectionId, disposition: .moveToLocalAccount, textContent: provider)
            }
            try await fixture.queue.read { db throws in
                #expect(try UUID.fetchOne(db, sql: "SELECT accountConnectionId FROM vaults") == (fail ? connectionId : nil))
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM transcript_segment_bodies") == (scenario == "textFailure" ? 0 : 2))
                if !fail { #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_content_state") == 0) }
                if fail {
                    #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_entity_state")! > 0)
                    #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_content_state")! > 0)
                }
            }
            #expect(changeRequests.withLock { $0 } == (scenario == "textFailure" ? 1 : 2))
            if scenario == "serverChanged" {
                // A retry synchronizes to the newer cursor before hydrating and validating again.
                try await repository.resolveVaultsForSignOut(connectionID: connectionId, disposition: .moveToLocalAccount, textContent: provider)
                #expect(changeRequests.withLock { $0 } == 4)
                #expect(try await fixture.queue.read { try VaultRecord.fetchOne($0, key: fixture.vaultId)?.accountConnectionId } == nil)
            }
        }

        @Test(arguments: [nil, "{}", #"{"sync":{"version":1}}"#, #"{"sync":{"version":2}}"#, #"{"sync":{"version":4}}"#])
        func incompatibleServerStopsMetadataSyncWithoutDiscardingExistingText(capabilities: String?) async throws {
            let fixture = try textFixture()
            let connectionId = try await fixture.queue.write { db in
                try db.execute(sql: "UPDATE vaults SET syncPullCursor = 'before'")
                try db
                    .execute(
                        sql: """
                        INSERT INTO transcript_segment_bodies(segmentId, text)
                        SELECT id, 'local body'
                        FROM transcript_segments
                        WHERE true
                        ON CONFLICT(segmentId) DO UPDATE SET text = excluded.text
                        """
                    )
                try db.execute(sql: "UPDATE sync_content_state SET complete = 1, residentRevision = 3")
                return try #require(try UUID.fetchOne(db, sql: "SELECT accountConnectionId FROM vaults"))
            }
            let calls = Mutex(0)
            let provider = provider(fixture) { _ in
                calls.withLock { $0 += 1 }
                if let capabilities { return (200, [:], Data(capabilities.utf8)) }
                return (404, [:], Data())
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let worker = await SyncWorker(dbQueue: fixture.queue, apiClient: provider.client)
            await #expect(throws: SyncHTTPError.self) {
                try await worker.synchronizeForTransfer(vaultId: fixture.vaultId, connectionId: connectionId)
            }
            #expect(calls.withLock { $0 } == 1)
            try await fixture.queue.read { db throws in
                #expect(try String.fetchOne(db, sql: "SELECT syncRecoveryState FROM vaults") == "updateRequired")
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM vaults") == "before")
                #expect(try String.fetchOne(db, sql: "SELECT text FROM transcript_segment_bodies") == "local body")
            }
        }

        @Test
        func metadataDeltaAdvancesWithoutFetchingAnyTextPage() async throws {
            let fixture = try textFixture()
            let connectionId = try await fixture.queue.write { db in
                try db.execute(sql: "UPDATE vaults SET syncPullCursor = 'before'")
                return try #require(try UUID.fetchOne(db, sql: "SELECT accountConnectionId FROM vaults"))
            }
            let payload = try JSONSerialization.data(withJSONObject: [
                "items": [[
                    "sequence": 1,
                    "entity": "transcript",
                    "entityId": fixture.meetingId.uuidString,
                    "action": "upsert",
                    "revision": 4,
                    "record": [
                        "meetingId": fixture.meetingId.uuidString,
                        "contentOmitted": true,
                        "contentPresent": true,
                        "contentCount": 10000,
                    ],
                ]],
                "cursor": "after", "highWaterCursor": "after", "hasMore": false,
            ])
            let calls = Mutex([String]())
            let provider = provider(fixture) { request in
                calls.withLock { $0.append(request.url!.path) }
                if request.url!.path.hasSuffix("/capabilities") {
                    return (200, [:], Data(#"{"sync":{"version":3},"futureFeature":{"enabled":true}}"#.utf8))
                }
                return (200, [:], payload)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let worker = await SyncWorker(dbQueue: fixture.queue, apiClient: provider.client)
            try await worker.synchronizeForTransfer(vaultId: fixture.vaultId, connectionId: connectionId)
            #expect(calls.withLock { $0.count } == 2)
            #expect(calls.withLock { $0.allSatisfy { !$0.contains("/text/") } })
            try await fixture.queue.read { db throws in
                #expect(try String.fetchOne(db, sql: "SELECT syncPullCursor FROM vaults") == "after")
                #expect(try Int.fetchOne(db, sql: "SELECT contentCount FROM sync_content_state WHERE entity = 'transcript'") == 10000)
                #expect(try Int.fetchOne(db, sql: "SELECT complete FROM sync_content_state WHERE entity = 'transcript'") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM transcript_segment_bodies") == 0)
            }
        }

        @Test(arguments: [TextContentEntity.summary, .file])
        func summaryAndFileBodiesHydrateAndEvictWithoutLosingHeaders(entity: TextContentEntity) async throws {
            let fixture = try textFixture()
            let id = entity == .summary ? fixture.meetingId : UUID.v7()
            let document = try SummaryDocument(title: "Remote", sections: [], tags: ["remote_tag"]).databaseJSONString()
            let values: [String?] = entity == .summary ? [document] : [nil, "cloudcaption"]
            var digest = TextContentDigest()
            for value in values {
                digest.add(value)
            }
            let manifest: [String: Any] = [
                "version": 1,
                "entity": entity.rawValue,
                "entityId": id.uuidString,
                "revision": 3,
                "present": true,
                "count": values.count,
                "byteCount": digest.byteCount,
                "sha256": digest.digestHex(),
            ]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest)
            let body: [String: Any] = entity == .summary
                ? manifest.merging(["record": ["title": "Remote", "document": document, "createdAt": "2026-01-01T00:00:00.000Z"]]) { _, new in new }
                : [
                    "id": id.uuidString,
                    "vaultId": fixture.vaultId.uuidString,
                    "revision": 3,
                    "checksum": "SHA-256:" + String(repeating: "0", count: 64),
                    "metadata": ["source": "screenshot", "ocr_text": NSNull(), "caption": "cloudcaption"],
                ]
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            try await fixture.queue.write { db in
                if entity == .summary {
                    try db.execute(
                        sql: "INSERT INTO summaries(meetingId, title, createdAt) VALUES (?, 'Remote', ?)",
                        arguments: [id, Date()]
                    )
                    try SummaryExportRecord.setURL("vault:///saved.md", meetingId: id, type: .vault, in: db)
                } else {
                    try FileRecord(
                        id: id,
                        vaultId: fixture.vaultId,
                        size: 0,
                        contentType: "image/png",
                        checksum: "SHA-256:" + String(repeating: "0", count: 64),
                        name: "image",
                        metadata: .init(source: .screenshot),
                        createdAt: .now,
                        updatedAt: .now,
                        remoteReference: ScreenshotRemoteReference(
                            origin: fixture.origin,
                            accountConnectionId: #require(try VaultRecord.fetchOne(db, key: fixture.vaultId)?.accountConnectionId),
                            fileId: id,
                            contentHash: String(repeating: "0", count: 64)
                        ).jsonString()
                    ).insert(db)
                    try MeetingFileRecord(id: id, meetingId: fixture.meetingId, fileId: id, capturedAt: .now, createdAt: .now).insert(db)
                }
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, ?, ?, 3)", arguments: [fixture.vaultId, entity.rawValue, id])
                try db.execute(
                    sql: "INSERT INTO sync_content_state(vaultId, entity, entityId) VALUES (?, ?, ?)",
                    arguments: [fixture.vaultId, entity.rawValue, id]
                )
            }
            let calls = Mutex(0)
            let provider = provider(fixture) { request in
                calls.withLock { $0 += 1 }
                return (200, [:], (request.url!.query ?? "").contains("manifest") ? manifestData : bodyData)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await provider.ensure(entity: entity, id: id, dbQueue: fixture.queue)
            let expectedHash = digest.digestHex()
            #expect(try await fixture.queue.read { try TextContentStore.fingerprint(entity: entity, id: id, in: $0)?.hash } == expectedHash)
            if entity == .file {
                try await fixture.queue.write { db in
                    try indexScreenshotDocument(id: id, generation: 1, in: db)
                    try db.execute(sql: "UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'fts'")
                }
                let store = MeetingAccessStore(database: fixture.queue, vaultID: fixture.vaultId)
                let hits = try store.queryScreenshots(.init(query: "cloudcaption"))
                #expect(hits.screenshots.count == 1)
                #expect(hits.screenshots.first?.detectedText.isEmpty == true)
                // Cached stale OCR remains readable offline; the overlay's explicit retry must fetch a new revision.
                try await fixture.queue.write { db in
                    try db.execute(sql: "UPDATE file_text_bodies SET caption = 'older' WHERE fileId = ?", arguments: [id])
                    try db.execute(sql: "UPDATE sync_content_state SET residentRevision = 2 WHERE entity = 'file'")
                    try db
                        .execute(
                            sql: """
                            INSERT INTO transcript_segment_bodies(segmentId, text)
                            SELECT id, 'cached'
                            FROM transcript_segments
                            WHERE true
                            ON CONFLICT(segmentId) DO UPDATE SET text = excluded.text
                            """
                        )
                    try db.execute(sql: "UPDATE sync_content_state SET complete = 1, residentRevision = 3 WHERE entity = 'transcript'")
                }
                let viewModel = CaptionViewModel()
                viewModel.loadMeeting(fixture.meetingId, dbQueue: fixture.queue, projectURL: nil, projectId: nil, vaultURL: nil)
                defer { viewModel.clearCurrentMeeting() }
                let before = calls.withLock { $0 }
                let cached = await viewModel.screenshotOCRState(id: id, contentProvider: provider)
                #expect(cached == .remote(ocrText: nil, caption: "older", state: .stale))
                #expect(calls.withLock { $0 } == before)
                let refreshed = await viewModel.screenshotOCRState(id: id, refresh: true, contentProvider: provider)
                #expect(refreshed == .remote(ocrText: nil, caption: "cloudcaption", state: .ready))
                #expect(calls.withLock { $0 } == before + 1)
                try await fixture.queue.write { db in
                    try db.execute(sql: "UPDATE sync_entity_state SET confirmedRevision = 4 WHERE entity = 'file'")
                }
                ImageURLProtocol.register(origin: fixture.origin) { _ in (503, [:], Data()) }
                let failed = await viewModel.screenshotOCRState(id: id, refresh: true, contentProvider: provider)
                #expect(failed == .remote(ocrText: nil, caption: "cloudcaption", state: .stale))
                try await fixture.queue.write { db in
                    try db.execute(sql: "UPDATE sync_entity_state SET confirmedRevision = 3 WHERE entity = 'file'")
                }
            }
            try await provider.trim(dbQueue: fixture.queue, capacity: 1)
            try await fixture.queue.read { db throws in
                if entity == .summary {
                    #expect(try String.fetchOne(db, sql: "SELECT title FROM summaries WHERE meetingId = ?", arguments: [id]) == "Remote")
                    #expect(try String.fetchOne(db, sql: "SELECT document FROM summary_bodies WHERE meetingId = ?", arguments: [id]) == nil)
                    #expect(try SummaryExportRecord.fetchOne(meetingId: id, type: .vault, in: db) != nil)
                    #expect(try String.fetchAll(db, sql: "SELECT name FROM tags") == ["remote_tag"])
                    #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM meeting_tags") == 1)
                } else {
                    #expect(try TextContentAccess.cachedFileText(fileId: id, in: db)?.caption == nil)
                    #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM search_documents WHERE kind = 'screenshot'") == 0)
                }
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions") == 0)
            }
            if entity == .summary {
                try await fixture.queue.write { db in
                    try db.execute(sql: "DELETE FROM meeting_tags WHERE meetingId = ?", arguments: [id])
                }
                try await provider.ensure(entity: entity, id: id, dbQueue: fixture.queue)
                try await fixture.queue.read { db throws in
                    #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM meeting_tags") == 0)
                    #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions") == 0)
                    #expect(try SummaryExportRecord.fetchOne(meetingId: id, type: .vault, in: db) != nil)
                }
                try await provider.trim(dbQueue: fixture.queue, capacity: 1)
                let replacement = try SummaryDocument(title: "Replacement", sections: []).databaseJSONString()
                var replacementDigest = TextContentDigest()
                replacementDigest.add(replacement)
                var replacementManifest = manifest
                replacementManifest["revision"] = 4
                replacementManifest["sha256"] = replacementDigest.digestHex()
                replacementManifest["byteCount"] = replacementDigest.byteCount
                let newManifestData = try JSONSerialization.data(withJSONObject: replacementManifest)
                var replacementBody = replacementManifest
                replacementBody["record"] = [
                    "title": "Replacement", "document": replacement, "createdAt": "2026-01-01T00:00:00.000Z",
                ]
                let newBodyData = try JSONSerialization.data(withJSONObject: replacementBody)
                ImageURLProtocol.register(origin: fixture.origin) { request in
                    (200, [:], (request.url!.query ?? "").contains("manifest") ? newManifestData : newBodyData)
                }
                try await fixture.queue.write { db in
                    try db.execute(sql: "UPDATE sync_entity_state SET confirmedRevision = 4 WHERE entity = 'summary'")
                }
                try await provider.ensure(entity: entity, id: id, dbQueue: fixture.queue)
                try await fixture.queue.read { db throws in
                    #expect(try SummaryExportRecord.fetchOne(meetingId: id, type: .vault, in: db) == nil)
                    #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_transactions") == 0)
                }
            }

        }

        private actor TextRequestGate {
            var count = 0
            private var isOpen = false
            private var started: CheckedContinuation<Void, Never>?
            private var waiting: [CheckedContinuation<Void, Never>] = []
            func wait() async {
                guard !isOpen else { return }
                count += 1
                if count == 2 { started?.resume()
                    started = nil
                }
                await withCheckedContinuation { waiting.append($0) }
            }

            func waitUntilTwoReadsStart() async {
                guard count < 2 else { return }
                await withCheckedContinuation { started = $0 }
            }

            func open() {
                isOpen = true
                let current = waiting
                waiting.removeAll()
                for continuation in current {
                    continuation.resume()
                }
            }
        }

        private func storageBytes(_ directory: URL) throws -> Int {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
                .reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        }

        struct TextFixture: Sendable {
            let queue: DatabaseQueue
            let vaultId: UUID
            let meetingId: UUID
            let segmentId: UUID
            let origin: String
            let hash: String
            let manifest: Data
            let firstPage: Data
            let secondPage: Data
            let secondPageCorrupt: Data

            func response(_ request: URLRequest) -> (Int, [String: String], Data) {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
                return (
                    200,
                    ["Content-Type": "application/json"],
                    query.contains { $0.name == "manifest" } ? manifest : query.contains { $0.name == "cursor" } ? secondPage : firstPage
                )
            }
        }

        func textFixture(path: String = ":memory:") throws -> TextFixture {
            let (queue, vaultId, meetingId) = try database(path: path)
            let segmentId = UUID.v7()
            let secondId = UUID.v7()
            let texts = ["first 日本語", "second 🙂"]
            let ids = [segmentId, secondId]
            var digest = TextContentDigest()
            var pages: [[String: Any]] = []
            for index in 0 ..< 2 {
                var pageDigest = TextContentDigest()
                for value in [ids[index].uuidString.lowercased(), texts[index]].enumerated() {
                    digest.add(value.element, body: value.offset == 1)
                    pageDigest.add(value.element, body: value.offset == 1)
                }
                let item: [String: Any] = [
                    "segmentId": ids[index].uuidString.lowercased(),
                    "startTime": index == 0 ? "2026-01-01T00:00:00.000Z" : "2026-01-01T00:00:01.000Z",
                    "text": texts[index],
                    "isConfirmed": true,
                ]
                pages.append([
                    "version": 1,
                    "revision": 3,
                    "sha256": pageDigest.digestHex(),
                    "byteCount": pageDigest.byteCount,
                    "count": 1,
                    "items": [item],
                    "nextCursor": index == 0 ? "page2" : NSNull(),
                ])
            }
            let origin = try queue.write { db -> String in
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'transcript', ?, 3)", arguments: [vaultId, meetingId])
                try db.execute(
                    sql: "INSERT INTO sync_content_state(vaultId, entity, entityId, contentCount) VALUES (?, 'transcript', ?, 2)",
                    arguments: [vaultId, meetingId]
                )
                try db.execute(
                    sql: """
                    INSERT INTO transcript_segments(id, meetingId, startTime, translatedText, isConfirmed, audioFeatureVersion, audioVoicedFrameRatio)
                    VALUES (?, ?, ?, 'local translation', 1, 1, 0.75)
                    """,
                    arguments: [segmentId, meetingId, Date(timeIntervalSince1970: 1_767_225_600)]
                )
                return try #require(try String.fetchOne(db, sql: "SELECT origin FROM dahlia_account_connections"))
            }
            let manifest: [String: Any] = [
                "version": 1,
                "entity": "transcript",
                "entityId": meetingId.uuidString.lowercased(),
                "revision": 3,
                "present": true,
                "count": 2,
                "byteCount": digest.byteCount,
                "sha256": digest.digestHex(),
            ]
            var corrupt = pages[1]
            corrupt["sha256"] = "invalid"
            return try TextFixture(
                queue: queue,
                vaultId: vaultId,
                meetingId: meetingId,
                segmentId: segmentId,
                origin: origin,
                hash: digest.digestHex(),
                manifest: JSONSerialization.data(withJSONObject: manifest),
                firstPage: JSONSerialization.data(withJSONObject: pages[0]),
                secondPage: JSONSerialization.data(withJSONObject: pages[1]),
                secondPageCorrupt: JSONSerialization.data(withJSONObject: corrupt)
            )
        }

        func provider(_ fixture: TextFixture, handler: @escaping ImageURLProtocol.Handler) -> MeetingContentProvider {
            ImageURLProtocol.register(origin: fixture.origin, handler: handler)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            return MeetingContentProvider(client: SyncAPIClient(
                session: URLSession(configuration: configuration),
                tokenProvider: { _, _ in "test-token" }
            ))
        }

        private func database(path: String = ":memory:") throws -> (DatabaseQueue, UUID, UUID) {
            let queue = try AppDatabaseManager(path: path).dbQueue
            let connection = DahliaAccountConnectionRecord(
                id: .v7(),
                origin: "https://text-\(UUID().uuidString.lowercased()).invalid",
                clientID: "test",
                createdAt: .now
            )
            var vault = VaultRecord(id: .v7(), path: nil, name: "Server", createdAt: .now, lastOpenedAt: .now)
            vault.accountConnectionId = connection.id
            vault.syncConfirmedConnectionId = connection.id
            let meeting = MeetingRecord(id: .v7(), vaultId: vault.id, projectId: nil, name: "Meeting", createdAt: .now, updatedAt: .now)
            try queue.write { db in
                try connection.insert(db)
                try vault.insert(db)
                try meeting.insert(db)
            }
            return (queue, vault.id, meeting.id)
        }
    }
#endif
