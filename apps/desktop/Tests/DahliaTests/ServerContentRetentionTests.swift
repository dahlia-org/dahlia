#if canImport(Testing)
    import DahliaMeetingAccess
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct ServerContentRetentionTests {
        @Test func settingsPersistDaysAndForeverWithSafeDefaults() throws {
            let name = "server-retention-\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            #expect(ServerContentRetention.days(in: defaults) == 0)
            #expect(!ServerContentRetention.allowsEviction(
                lastUsedAt: .distantPast, now: .now, days: ServerContentRetention.days(in: defaults)
            ))
            for value in [1, 45, 365, 0] {
                defaults.set(value, forKey: ServerContentRetention.defaultsKey)
                let reopened = try #require(UserDefaults(suiteName: name))
                #expect(ServerContentRetention.days(in: reopened) == value)
            }
            defaults.set(-1, forKey: ServerContentRetention.defaultsKey)
            #expect(ServerContentRetention.days(in: defaults) == 0)
            defaults.set("invalid", forKey: ServerContentRetention.defaultsKey)
            #expect(ServerContentRetention.days(in: defaults) == 0)
        }

        @Test(arguments: [1, 30, 365])
        func expiryUsesTheExactMinimumRetentionBoundary(days: Int) {
            let used = Date(timeIntervalSince1970: 1_000_000)
            let boundary = used.addingTimeInterval(Double(days) * 86400)
            #expect(!ServerContentRetention.allowsEviction(lastUsedAt: used, now: boundary.addingTimeInterval(-1), days: days))
            #expect(ServerContentRetention.allowsEviction(lastUsedAt: used, now: boundary, days: days))
            #expect(!ServerContentRetention.allowsEviction(lastUsedAt: used, now: .distantFuture, days: 0))
            #expect(!ServerContentRetention.allowsEviction(lastUsedAt: nil, now: boundary, days: days))
        }

        @Test(arguments: ["text", "images", "index"])
        func foreverSkipsDatabaseAndIndexWork(entry: String) async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "retention-skip-\(UUID.v7())")
            defer { try? FileManager.default.removeItem(at: root) }
            if entry == "text" {
                let database = try AppDatabaseManager(path: ":memory:")
                try database.close()
                let provider = MeetingContentProvider()
                try await provider.trim(dbQueue: database.dbQueue, retentionDays: 0)
                await #expect(throws: (any Error).self) {
                    try await provider.trim(dbQueue: database.dbQueue, retentionDays: 1)
                }
            } else if entry == "images" {
                let database = try AppDatabaseManager(path: ":memory:")
                try database.close()
                let provider = try ScreenshotContentProvider(cache: ScreenshotFileStore(directory: root))
                try await provider.trimFiles(dbQueue: database.dbQueue, retentionDays: 0)
                await #expect(throws: (any Error).self) {
                    try await provider.trimFiles(dbQueue: database.dbQueue, retentionDays: 1)
                }
            } else {
                let cache = try ScreenshotFileStore(directory: root)
                let index = try DatabaseQueue(path: root.appending(path: "index.sqlite").path)
                try await index.write { try $0.execute(sql: "DROP TABLE images") }
                try cache.trim(budget: 0, protecting: [], retentionDays: 0)
                #expect(throws: (any Error).self) { try cache.trim(budget: 0, protecting: [], retentionDays: 1) }
            }
        }

        @Test func transcriptSurvivesCapacityPressureAndForeverThenCanBeRefetched() async throws {
            let support = TextContentTests()
            let fixture = try support.textFixture()
            let provider = support.provider(fixture) { fixture.response($0) }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue)
            let used = try await fixture.queue.read { db in
                try #require(try Date.fetchOne(db, sql: "SELECT lastAccessedAt FROM sync_content_state WHERE entity = 'transcript'"))
            }
            let boundary = used.addingTimeInterval(30 * 86400)
            try await provider.trim(dbQueue: fixture.queue, capacity: 1, now: boundary.addingTimeInterval(-1), retentionDays: 30)
            #expect(try await fixture.queue.read { try TextContentAccess.transcript(meetingId: fixture.meetingId, in: $0).count } == 2)
            try await provider.trim(dbQueue: fixture.queue, capacity: 1, now: .distantFuture, retentionDays: 0)
            #expect(try await fixture.queue.read { try TextContentAccess.transcript(meetingId: fixture.meetingId, in: $0).count } == 2)
            try await provider.trim(dbQueue: fixture.queue, capacity: 1, now: boundary, retentionDays: 30)
            #expect(try await fixture.queue
                .read { try TextContentAccess.availability(entity: .transcript, id: fixture.meetingId, in: $0).state } == .missing)
            try await fixture.queue.write { db in
                try db.execute(sql: "UPDATE sync_content_state SET lastAccessedAt = ?", arguments: [Date(timeIntervalSince1970: 1_000_000)])
            }
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue, prefetchBudget: Int.max)
            #expect(try await fixture.queue.read { try TextContentAccess.transcript(meetingId: fixture.meetingId, in: $0).count } == 2)
            #expect(try await fixture.queue
                .read { try Date.fetchOne($0, sql: "SELECT lastAccessedAt FROM sync_content_state") } != Date(timeIntervalSince1970: 1_000_000))
        }

        @Test func maintenanceDoesNotRenewTextRetentionButLocalEditsAndReadsDo() async throws {
            let support = TextContentTests()
            let fixture = try support.textFixture()
            let provider = support.provider(fixture) { fixture.response($0) }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue, prefetchBudget: Int.max)
            let old = Date(timeIntervalSince1970: 1_000_000)
            try await fixture.queue.write { db in
                try db.execute(sql: "UPDATE sync_content_state SET lastAccessedAt = ?", arguments: [old])
            }
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue, refresh: true, prefetchBudget: Int.max)
            #expect(try await fixture.queue.read { try Date.fetchOne($0, sql: "SELECT lastAccessedAt FROM sync_content_state") } == old)
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue)
            #expect(try await fixture.queue.read { try Date.fetchOne($0, sql: "SELECT lastAccessedAt FROM sync_content_state") } != old)
            try await fixture.queue.write { db in
                try db.execute(sql: "UPDATE sync_content_state SET lastAccessedAt = ?", arguments: [old])
                let content = try #require(try TextContentAccess.transcript(meetingId: fixture.meetingId, in: db).first)
                let patch = SyncOperationDraft(entity: .transcript, action: .patch, entityId: fixture.meetingId)
                try SyncTransactionRecorder.record(
                    workspaceId: fixture.workspaceId,
                    operations: [patch],
                    transcriptSegments: [patch.id: [.init(content)]],
                    in: db
                )
                #expect(try Date.fetchOne(db, sql: "SELECT lastAccessedAt FROM sync_content_state") != old)
            }
            try await provider.trim(dbQueue: fixture.queue, capacity: 1, now: .distantFuture, retentionDays: 1)
            #expect(try await fixture.queue.read { try TextContentAccess.transcript(meetingId: fixture.meetingId, in: $0).count } == 2)
        }

        @Test func imagesKeepTheirMinimumAgeAndInternalReadsDoNotRenewIt() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "image-retention-\(UUID.v7())")
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = try ScreenshotFileStore(directory: root)
            let bytes = Data("image".utf8)
            let source = ScreenshotRemoteReference(
                origin: "https://example.invalid", accountConnectionId: .v7(), fileId: .v7(),
                contentHash: ScreenshotRemoteReference.digest(bytes)
            )
            let image = ScreenshotContent(data: bytes, mimeType: "image/png", variant: .original)
            let used = Date(timeIntervalSince1970: 1_000_000)
            let boundary = used.addingTimeInterval(30 * 86400)
            try cache.write(image, source: source, now: used)
            try cache.trim(budget: 0, protecting: [], now: boundary.addingTimeInterval(-1), retentionDays: 30)
            #expect(try cache.read(source, variant: .original, recordAccess: false)?.data == bytes)
            try cache.trim(budget: 0, protecting: [], now: .distantFuture, retentionDays: 0)
            #expect(try cache.read(source, variant: .original, recordAccess: false)?.data == bytes)
            try cache.write(image, source: source, recordAccess: false)
            try cache.trim(budget: 0, protecting: [], now: boundary, retentionDays: 30)
            #expect(try cache.read(source, variant: .original, recordAccess: false) == nil)
            try cache.write(image, source: source, now: used)
            try cache.write(
                ScreenshotContent(data: bytes, mimeType: "image/png", variant: .thumbnail),
                source: source,
                recordAccess: false,
                now: used
            )
            #expect(try cache.read(source, variant: .thumbnail)?.data == bytes)
            try cache.trim(budget: 0, protecting: [], now: boundary, retentionDays: 30)
            #expect(try cache.read(source, variant: .original, recordAccess: false)?.data == bytes)
        }

        @Test func offlineRestartKeepsTranscriptAndUnsentEdits() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "offline-retention-\(UUID.v7())")
            defer { try? FileManager.default.removeItem(at: root) }
            let support = TextContentTests()
            let path = root.appending(path: "data.sqlite").path
            let fixture = try support.textFixture(path: path)
            let provider = support.provider(fixture) { fixture.response($0) }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: fixture.queue)
            try await fixture.queue.write { db in
                let content = try #require(try TextContentAccess.transcript(meetingId: fixture.meetingId, in: db).first)
                let patch = SyncOperationDraft(entity: .transcript, action: .patch, entityId: fixture.meetingId)
                try SyncTransactionRecorder.record(
                    workspaceId: fixture.workspaceId,
                    operations: [patch],
                    transcriptSegments: [patch.id: [.init(content)]],
                    in: db
                )
            }
            try fixture.queue.close()
            ImageURLProtocol.register(origin: fixture.origin) { _ in
                Issue.record("A complete local transcript must not require a Server request")
                return (503, [:], Data())
            }
            let reopened = try AppDatabaseManager(path: path).dbQueue
            try await provider.ensure(entity: .transcript, id: fixture.meetingId, dbQueue: reopened)
            #expect(try await reopened.read { try TextContentAccess.transcript(meetingId: fixture.meetingId, in: $0).count } == 2)
            #expect(try await SyncTransactionQueue.hasPending(workspaceId: fixture.workspaceId, dbQueue: reopened))
            try reopened.close()
        }

        @Test func documentsRespectAgeForeverAndLocalEdits() async throws {
            let fixture = try TextContentTests().textFixture()
            let persistence = DocumentPersistence(dbQueue: fixture.queue)
            let record = DocumentRecord(
                id: .v7(), workspaceId: fixture.workspaceId, meetingId: fixture.meetingId,
                checkpoint: "AAA=", createdAt: .now, updatedAt: .now
            )
            let update = try await persistence.legacyImport(text: "retained notes")
            try await persistence.receive(document: record, update: update, generation: .v7(), revision: 1, validate: { _ in })
            let old = Date(timeIntervalSince1970: 1_000_000)
            try await fixture.queue.write { db throws in
                try db.execute(sql: "UPDATE documents SET lastAccessedAt = ?", arguments: [old])
                #expect(try DocumentRetention.evict(
                    documentID: record.id,
                    protectedWorkspaces: [],
                    now: old.addingTimeInterval(30 * 86400 - 1),
                    retentionDays: 30,
                    in: db
                ) == 0)
                #expect(try DocumentRetention
                    .evict(documentID: record.id, protectedWorkspaces: [], now: .distantFuture, retentionDays: 0, in: db) == 0)
            }
            try await persistence.receive(document: record, update: update, generation: .v7(), revision: 2, validate: { _ in })
            #expect(try await fixture.queue.read { try DocumentRecord.fetchOne($0, key: record.id)?.lastAccessedAt } == old)
            let edit = try await persistence.legacyImport(text: "local edit")
            try await persistence.append(meetingID: fixture.meetingId, update: edit, local: true)
            try await fixture.queue.read { db throws in
                #expect(try DocumentRecord.fetchOne(db, key: record.id)?.lastAccessedAt != old)
                #expect(try DocumentRetention
                    .evict(documentID: record.id, protectedWorkspaces: [], now: .distantFuture, retentionDays: 1, in: db) == 0)
            }
        }

        @Test func migrationInitializesUnknownResidentDatesWithoutChangingContent() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v53_documentsSyncAndBackgroundJobs")
            let workspace = WorkspaceRecord(id: .v7(), name: "Preserved", createdAt: .now, lastOpenedAt: .now)
            let meeting = MeetingRecord(id: .v7(), workspaceId: workspace.id, name: "Meeting", createdAt: .now, updatedAt: .now)
            let old = Date(timeIntervalSince1970: 1_000_000)
            let document = DocumentRecord(
                id: .v7(), workspaceId: workspace.id, meetingId: meeting.id,
                checkpoint: "AAA=", createdAt: old, updatedAt: old
            )
            try queue.write { db in
                try workspace.insert(db)
                try meeting.insert(db)
                try document.insert(db)
                try SummaryRecord(meetingId: meeting.id, title: "Preserved", createdAt: old).insert(db)
                try SummaryBodyRecord(meetingId: meeting.id, document: "preserved text").insert(db)
                try db.execute(sql: """
                INSERT INTO sync_content_state(workspace_id, entity, entityId, complete, lastAccessedAt)
                VALUES (?, 'summary', ?, 1, NULL), (?, 'transcript', ?, 0, NULL), (?, 'file', ?, 1, ?)
                """, arguments: [workspace.id, meeting.id, workspace.id, meeting.id, workspace.id, UUID.v7(), old])
            }
            let started = Date()
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db throws in
                #expect(try #require(try Date.fetchOne(db, sql: "SELECT lastAccessedAt FROM sync_content_state WHERE entity = 'summary'")) >= started
                    .addingTimeInterval(-1))
                #expect(try Date.fetchOne(db, sql: "SELECT lastAccessedAt FROM sync_content_state WHERE entity = 'transcript'") == nil)
                #expect(try Date.fetchOne(db, sql: "SELECT lastAccessedAt FROM sync_content_state WHERE entity = 'file'") == old)
                #expect(try DocumentRecord.fetchOne(db, key: document.id)?.lastAccessedAt != nil)
                #expect(try SummaryBodyRecord.fetchOne(db, key: meeting.id)?.document == "preserved text")
                #expect(try DocumentRecord.fetchOne(db, key: document.id)?.checkpoint == document.checkpoint)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }
    }
#endif
