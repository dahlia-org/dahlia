#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct ScreenshotFilePersistenceTests {
        @Test(arguments: ["none", "meeting", "link"])
        func captureUploadAndAcknowledgementReuseOneFile(laterDeletion: String) async throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            try await fixture.provider.persistCapture(fixture.image, dbQueue: fixture.database.dbQueue)
            let stored = try #require(try await fixture.database.dbQueue.read { try MeetingScreenshotRecord.fetchOne($0, key: fixture.image.id) })
            #expect(stored.imageData == nil)
            #expect(stored.remoteReference == nil)
            #expect(stored.localSource == fixture.source)
            #expect(try await fixture.provider.content(id: stored.id, dbQueue: fixture.database.dbQueue).data == fixture.bytes)
            let modified = try FileManager.default.attributesOfItem(atPath: fixture.imageURL.path)[.modificationDate] as? Date
            let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.database.dbQueue))
            let operation = try #require(transaction.operations.first)
            #expect(try await fixture.provider.attachment(operationId: operation.id, dbQueue: fixture.database.dbQueue)?.bytes == fixture.bytes)
            // Staging/upload completion is insufficient to release an original.
            try await fixture.provider.trimFiles(dbQueue: fixture.database.dbQueue, budget: 0)
            #expect(FileManager.default.fileExists(atPath: fixture.imageURL.path))
            let response = try SyncJSON.decoder.decode(SyncTransactionResponse.self, from: Data("""
            {"id":"\(transaction.id)","status":"committed","cursor":"after-image","records":[
              {"entity":"file","id":"\(stored.originalFileId)","revision":1,"record":{
                "uri":"/Volumes/catalog/schema/volume/files/\(stored.originalFileId.uuidString.lowercased())/original",
                "offset":0,"size":\(fixture.bytes.count),"content_type":"image/png","checksum":"SHA-256:\(fixture.source.contentHash)",
                "name":"capture","metadata":{"source":"screenshot"},
                "createdAt":"2026-09-06T00:00:00Z","updatedAt":"2026-09-06T00:00:00Z"
              }},
              {"entity":"meeting_file","id":"\(stored.id)","revision":1,"record":{
                "meetingId":"\(stored.meetingId)","fileId":"\(stored.originalFileId)",
                "capturedAt":"\(stored.capturedAt.ISO8601Format())","createdAt":"2026-09-06T00:00:00Z"
              }}
            ]}
            """.utf8))
            let repository = MeetingRepository(dbQueue: fixture.database.dbQueue)
            if laterDeletion == "meeting" {
                try repository.deleteMeeting(id: stored.meetingId)
            } else if laterDeletion == "link" {
                _ = try await repository.deleteScreenshots(ids: [stored.id], meetingId: stored.meetingId)
            }
            try await SyncTransactionQueue.complete(transaction, response: response, dbQueue: fixture.database.dbQueue)
            if laterDeletion != "none" {
                #expect(try await fixture.database.dbQueue.read { try MeetingFileRecord.fetchOne($0, key: stored.id) } == nil)
                let next = try #require(try await SyncTransactionQueue.claim(dbQueue: fixture.database.dbQueue))
                #expect(next.operations.count == 1)
                #expect(next.operations.first?.action == .delete)
                #expect(next.operations.first?.entity == (laterDeletion == "meeting" ? .meeting : .meetingFile))
                #expect(try await fixture.database.dbQueue.read { db in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT confirmedRevision FROM sync_entity_state WHERE entity = 'meeting_file' AND entityId = ?",
                        arguments: [stored.id]
                    )
                } == 1)
                return
            }
            #expect(try FileManager.default.attributesOfItem(atPath: fixture.imageURL.path)[.modificationDate] as? Date == modified)
            #expect(try fixture.files.read(fixture.source, variant: .original)?.data == fixture.bytes)
            try await fixture.provider.trimFiles(dbQueue: fixture.database.dbQueue, budget: 0)
            #expect(!FileManager.default.fileExists(atPath: fixture.imageURL.path))
            try await fixture.database.dbQueue.read { db in
                let image = try #require(try MeetingScreenshotRecord.fetchOne(db, key: stored.id))
                #expect(image.imageData == nil)
                #expect(image.remoteSource == fixture.source)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations") == 0)
                #expect(try VaultRecord.fetchOne(db, key: fixture.vault.id)?.syncPullCursor == "cursor")
            }
        }

        @Test
        func captureFailureNeverPublishesARecordWithoutItsFile() async throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            let queue = fixture.database.dbQueue
            try FileManager.default.createDirectory(at: fixture.imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([99]).write(to: fixture.imageURL)
            await #expect(throws: ScreenshotContentError.integrityFailure) {
                try await fixture.provider.persistCapture(fixture.image, dbQueue: queue)
            }
            #expect(try await queue.read { try MeetingScreenshotRecord.fetchCount($0) } == 0)
            #expect(try Data(contentsOf: fixture.imageURL) == Data([99]))
            try FileManager.default.removeItem(at: fixture.imageURL)
            try await queue.write { db in
                try db
                    .execute(
                        sql: "CREATE TRIGGER reject_capture BEFORE INSERT ON meeting_files BEGIN SELECT RAISE(ABORT, 'injected commit failure'); END"
                    )
            }
            await #expect(throws: (any Error).self) { try await fixture.provider.persistCapture(fixture.image, dbQueue: queue) }
            #expect(try fixture.files.read(fixture.source, variant: .original)?.data == fixture.bytes)
            #expect(try await queue.read { try MeetingScreenshotRecord.fetchCount($0) } == 0)
            #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_operations") } == 0)
            try await queue.write { try $0.execute(sql: "DROP TRIGGER reject_capture") }
            try await fixture.provider.persistCapture(fixture.image, dbQueue: queue)
            #expect(try await queue.read { try MeetingScreenshotRecord.fetchOne($0, key: fixture.image.id)?.imageData } == nil)
            #expect(try fixture.files.read(fixture.source, variant: .original)?.data == fixture.bytes)
        }

        @Test
        func restartConflictAndCorruptionCannotEvictPendingFiles() async throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            let queue = fixture.database.dbQueue
            try await fixture.provider.persistCapture(fixture.image, dbQueue: queue)
            let transaction = try #require(try await SyncTransactionQueue.claim(dbQueue: queue))
            let operation = try #require(transaction.operations.first)
            try await SyncTransactionQueue.block(transaction, reason: .conflict, response: Data("{}".utf8), dbQueue: queue)
            let restarted = try ScreenshotContentProvider(cache: ScreenshotFileStore(directory: fixture.directory))
            try await restarted.trimFiles(dbQueue: queue, budget: 0)
            #expect(try await restarted.attachment(operationId: operation.id, dbQueue: queue)?.bytes == fixture.bytes)
            try Data([99]).write(to: fixture.imageURL, options: .atomic)
            await #expect(throws: ScreenshotContentError.integrityFailure) {
                try await restarted.attachment(operationId: operation.id, dbQueue: queue)
            }
            try await restarted.trimFiles(dbQueue: queue, budget: 0)
            #expect(try Data(contentsOf: fixture.imageURL) == Data([99]))
            let blockedReason = try await queue.read { db in
                try String.fetchOne(db, sql: "SELECT blockedReason FROM sync_transactions WHERE id = ?", arguments: [transaction.id])
            }
            #expect(blockedReason == "conflict")
        }

        @Test
        func readOnlyHelperReadsPendingFilesWithoutWritingOrDeleting() async throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            try await fixture.provider.persistCapture(fixture.image, dbQueue: fixture.database.dbQueue)
            let files = try ScreenshotFileStore(directory: fixture.directory, readOnly: true)
            let helper = try MeetingAccessStore(
                databaseURL: fixture.databaseURL, vaultID: fixture.vault.id, screenshotCache: files,
                imageResolver: { _, _, _ in throw ScreenshotContentError.unavailable }
            )
            #expect(try helper.screenshot(meetingID: fixture.image.meetingId, screenshotID: fixture.image.id, originalSize: true).imageData == fixture
                .bytes)
            #expect(throws: ScreenshotContentError.unavailable) { try files.trim(budget: 0, protecting: []) }
            try Data([99]).write(to: fixture.imageURL, options: .atomic)
            #expect(throws: ScreenshotContentError.integrityFailure) { try files.read(fixture.source, variant: .original) }
            #expect(FileManager.default.fileExists(atPath: fixture.imageURL.path))
        }

        @Test
        func localCaptureAndFailedAdoptionKeepTheOriginalFile() async throws {
            let fixture = try Fixture(local: true)
            defer { fixture.removeFiles() }
            let queue = fixture.database.dbQueue
            try await fixture.provider.persistCapture(fixture.image, dbQueue: queue)
            #expect(FileManager.default.fileExists(atPath: fixture.imageURL.path))
            #expect(try await queue.read { try MeetingScreenshotRecord.fetchOne($0, key: fixture.image.id)?.imageData } == nil)
            #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_operations") } == 0)
            try await queue.write { db in
                try db.execute(sql: """
                CREATE TRIGGER reject_adoption BEFORE UPDATE OF accountConnectionId ON vaults
                WHEN NEW.accountConnectionId IS NOT NULL BEGIN SELECT RAISE(ABORT, 'injected adoption failure'); END
                """)
            }
            let repository = MeetingRepository(dbQueue: queue)
            await #expect(throws: (any Error).self) {
                try await repository.adoptVaultForServerSync(
                    id: fixture.vault.id,
                    connectionID: fixture.connection.id,
                    serverVault: nil,
                    screenshotContent: fixture.provider
                )
            }
            try await queue.read { db throws in
                #expect(try VaultRecord.fetchOne(db, key: fixture.vault.id)?.accountConnectionId == nil)
                #expect(try MeetingScreenshotRecord.fetchOne(db, key: fixture.image.id)?.imageData == nil)
                #expect(try MeetingScreenshotRecord.fetchOne(db, key: fixture.image.id)?.localReference == fixture.source.jsonString())
            }
            try await queue.write { try $0.execute(sql: "DROP TRIGGER reject_adoption") }
            _ = try await repository.adoptVaultForServerSync(
                id: fixture.vault.id,
                connectionID: fixture.connection.id,
                serverVault: nil,
                screenshotContent: fixture.provider
            )
            try await fixture.provider.trimFiles(dbQueue: queue, budget: 0)
            #expect(try fixture.files.read(fixture.source, variant: .original)?.data == fixture.bytes)
            #expect(try await queue.read { try MeetingScreenshotRecord.fetchOne($0, key: fixture.image.id)?.imageData } == nil)
            try await SyncInitialSnapshotBuilder.enqueuePending(dbQueue: queue, screenshotContent: fixture.provider)
            let attachmentCount = try await queue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations WHERE attachmentReference IS NOT NULL AND attachmentBytes IS NULL")
            }
            #expect(attachmentCount == 1)
        }

        @Test
        func failedLegacyFileMigrationPreservesBlobAndCanRetry() async throws {
            let fixture = try Fixture()
            defer { fixture.removeFiles() }
            let queue = fixture.database.dbQueue
            try await queue.write { try fixture.image.insertLegacyForTesting($0) }
            try FileManager.default.createDirectory(at: fixture.imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([99]).write(to: fixture.imageURL)
            await #expect(throws: ScreenshotContentError.integrityFailure) {
                try await fixture.provider.migrateLegacyImages(vaultId: fixture.vault.id, dbQueue: queue)
            }
            #expect(try await queue.read { try MeetingScreenshotRecord.fetchOne($0, key: fixture.image.id)?.imageData } == fixture.bytes)
            try FileManager.default.removeItem(at: fixture.imageURL)
            try await fixture.provider.migrateLegacyImages(vaultId: fixture.vault.id, dbQueue: queue)
            #expect(try await queue.read { try MeetingScreenshotRecord.fetchOne($0, key: fixture.image.id)?.imageData } == nil)
            #expect(try fixture.files.read(fixture.source, variant: .original)?.data == fixture.bytes)
        }

        private struct Fixture {
            let root: URL
            let directory: URL
            let databaseURL: URL
            let database: AppDatabaseManager
            let files: ScreenshotFileStore
            let provider: ScreenshotContentProvider
            let connection: DahliaAccountConnectionRecord
            let vault: VaultRecord
            let image: MeetingScreenshotRecord
            let bytes: Data
            let source: ScreenshotRemoteReference
            var imageURL: URL { directory.appending(path: "\(source.cacheKey(variant: .original))") }

            @MainActor
            init(local: Bool = false) throws {
                root = FileManager.default.temporaryDirectory.appending(path: "image-persistence-\(UUID().uuidString)")
                directory = root.appending(path: "FileStore")
                databaseURL = root.appending(path: "test.sqlite")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                database = try AppDatabaseManager(path: databaseURL.path)
                files = try ScreenshotFileStore(directory: directory)
                provider = ScreenshotContentProvider(cache: files)
                connection = DahliaAccountConnectionRecord(
                    id: .v7(),
                    origin: "https://\(UUID().uuidString.lowercased()).example.test",
                    clientID: "test",
                    createdAt: .now
                )
                var vault = VaultRecord(id: .v7(), path: nil, name: "Files", createdAt: .now, lastOpenedAt: .now)
                if !local {
                    vault.accountConnectionId = connection.id
                    vault.syncConfirmedConnectionId = connection.id
                    vault.syncPullCursor = "cursor"
                }
                self.vault = vault
                let meeting = MeetingRecord(id: .v7(), vaultId: vault.id, projectId: nil, name: "Meeting", createdAt: .now, updatedAt: .now)
                bytes = try #require(TestScreenshotImageFixture.data(using: .png))
                image = MeetingScreenshotRecord(id: .v7(), meetingId: meeting.id, capturedAt: .now, imageData: bytes, mimeType: "image/png")
                source = ScreenshotRemoteReference(
                    origin: local ? "" : connection.origin,
                    accountConnectionId: local ? nil : connection.id,
                    fileId: image.id,
                    contentHash: ScreenshotRemoteReference.digest(bytes)
                )
                try database.dbQueue.write { db in
                    try connection.insert(db)
                    try vault.insert(db)
                    try meeting.insert(db)
                }
            }

            func removeFiles() {
                try? database.close()
                try? FileManager.default.removeItem(at: root)
            }
        }
    }
#endif
