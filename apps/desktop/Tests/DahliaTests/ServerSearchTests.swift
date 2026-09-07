#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct ServerSearchTests {
        @Test
        func preservesRanksWithoutHydratingBodiesAndSeparatesPending() async throws {
            let fixture = try ServerSearchFixture()
            let second = UUID.v7()
            let pendingProject = UUID.v7()
            try await fixture.queue.write { db in
                try ProjectRecord(id: pendingProject, vaultId: fixture.vaultId, path: "未同期", createdAt: .now).insert(db)
                try MeetingRecord(id: second, vaultId: fixture.vaultId, projectId: nil, name: "Second", createdAt: .now, updatedAt: .now).insert(db)
                for id in [fixture.meetingId, second] {
                    try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'meeting', ?, 1)", arguments: [fixture.vaultId, id])
                }
                try db.execute(sql: "UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'fts'")
            }
            let hits = [second, fixture.meetingId].map { id in
                [
                    "id": id.uuidString,
                    "meetingId": id.uuidString,
                    "kind": "meeting",
                    "title": "Server title",
                    "date": "2026-09-03T00:00:00Z",
                    "snippet": "Server-only summary",
                ]
            }
            let response = try fixture.response(meetings: hits)
            let paths = Mutex<[String]>([])
            let provider = fixture.provider { request in
                paths.withLock { $0.append(request.url!.path) }
                if request.url!.path == "/api/v1/capabilities" { return (200, [:], Data(#"{"searchVersion":1}"#.utf8)) }
                #expect(request.httpMethod == "POST")
                return (200, [:], response)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let ranked = try await MeetingRepository.serverSearch(
                vaultId: fixture.vaultId,
                criteria: .init(),
                dbQueue: fixture.queue,
                contentProvider: provider
            )
            #expect(ranked.meetings.map(\.id) == [second, fixture.meetingId])
            #expect(ranked.meetings.allSatisfy { $0.searchMatchContext?.text == "Server-only summary" })
            #expect(ranked.pendingMeetings.isEmpty)
            #expect(ranked.pendingProjects.map(\.id) == [pendingProject])
            let model = MainSearchModel()
            model.applyServerSearch(ranked)
            #expect(model.meetings.map(\.id) == [second, fixture.meetingId])
            model.resultKind = "project"
            #expect(model.meetings.isEmpty)
            #expect(model.resultIDs == [.project(pendingProject)])
            try await fixture.queue.write { db in
                try db.execute(sql: "DELETE FROM sync_entity_state WHERE entity = 'meeting' AND entityId = ?", arguments: [second])
            }
            let pending = try await MeetingRepository.serverSearch(
                vaultId: fixture.vaultId,
                criteria: .init(),
                dbQueue: fixture.queue,
                contentProvider: provider
            )
            #expect(pending.meetings.map(\.id) == [fixture.meetingId])
            #expect(pending.pendingMeetings.map(\.id) == [second])
            #expect(paths.withLock { $0 } == ["/api/v1/capabilities", "/api/v1/search", "/api/v1/capabilities", "/api/v1/search"])
        }

        @Test(arguments: ["recent", "date", "project"])
        func pendingScreenshotsSupportFilterOnlySearches(mode: String) async throws {
            let fixture = try ServerSearchFixture()
            let project = UUID.v7()
            let imageId = UUID.v7()
            let capturedAt = Date(timeIntervalSince1970: 1_780_000_000)
            try await fixture.queue.write { db in
                try ProjectRecord(id: project, vaultId: fixture.vaultId, path: "Project", createdAt: .now).insert(db)
                try db.execute(sql: "UPDATE meetings SET projectId = ?", arguments: [project])
                try MeetingScreenshotRecord(
                    id: imageId, meetingId: fixture.meetingId, sessionId: nil, capturedAt: capturedAt,
                    imageData: Data([1]), mimeType: "image/png"
                ).insertLegacyForTesting(db)
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'meeting', ?, 1)", arguments: [fixture.vaultId, fixture.meetingId])
                try db.execute(sql: "UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'fts'")
            }
            let response = try fixture.response(meetings: [])
            let provider = fixture.provider { request in
                if request.url!.path == "/api/v1/capabilities" { return (200, [:], Data(#"{"searchVersion":1}"#.utf8)) }
                return (200, [:], response)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            var criteria = MeetingSearchCriteria()
            if mode == "date" { criteria.startDate = capturedAt
                criteria.endDate = capturedAt.addingTimeInterval(1)
            }
            if mode == "project" { criteria.projectIDs = [project] }
            let result = try await MeetingRepository.serverSearch(
                vaultId: fixture.vaultId, criteria: criteria, dbQueue: fixture.queue, contentProvider: provider
            )
            #expect(result.pendingScreenshots.map(\.id) == [imageId])
            criteria.pendingOnly = true
            criteria.startDate = capturedAt.addingTimeInterval(1)
            criteria.endDate = nil
            let excluded = try await MeetingRepository.searchScreenshotPage(
                vaultID: fixture.vaultId,
                criteria: criteria,
                limit: 100,
                dbQueue: fixture.queue
            )
            #expect(excluded.items.isEmpty)
            criteria.startDate = nil
            criteria.pendingOnly = false
            let local = try await MeetingRepository.searchScreenshotPage(
                vaultID: fixture.vaultId,
                criteria: criteria,
                limit: 100,
                dbQueue: fixture.queue
            )
            #expect(local.items.isEmpty)
        }

        @Test
        func pendingOwnershipExcludesNonmatchingCanonicalHitsAndRecoversAfterSync() async throws {
            let fixture = try ServerSearchFixture()
            let imageId = UUID.v7()
            let transactionId = UUID.v7()
            try await fixture.queue.write { db in
                try db.execute(sql: "UPDATE meetings SET name = 'Renamed'")
                try MeetingScreenshotRecord(
                    id: imageId, meetingId: fixture.meetingId, sessionId: nil, capturedAt: .now,
                    imageData: Data([1]), mimeType: "image/png", ocrText: "Changed"
                ).insertLegacyForTesting(db)
                for (entity, id) in [("meeting", fixture.meetingId), ("meeting_file", imageId)] {
                    try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, ?, ?, 1)", arguments: [fixture.vaultId, entity, id])
                }
                try db.execute(
                    sql: "INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt) SELECT ?, id, accountConnectionId, ?, ? FROM vaults",
                    arguments: [transactionId, Date(), Date()]
                )
                for (position, entry) in [("meeting", fixture.meetingId), ("file", imageId)].enumerated() {
                    try db.execute(
                        sql: "INSERT INTO sync_operations(transactionId, position, id, entity, action, entityId, payloadJSON) VALUES (?, ?, ?, ?, 'upsert', ?, '{}')",
                        arguments: [transactionId, position, UUID.v7(), entry.0, entry.1]
                    )
                }
                try db.execute(sql: "UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'fts'")
            }
            let response = try fixture.response(
                meetings: [[
                    "id": fixture.meetingId.uuidString,
                    "meetingId": fixture.meetingId.uuidString,
                    "kind": "meeting",
                    "title": "Obsolete",
                    "date": "2026-09-03T00:00:00Z",
                    "snippet": "Old",
                ]],
                screenshots: [[
                    "id": imageId.uuidString,
                    "meetingId": fixture.meetingId.uuidString,
                    "fileId": imageId.uuidString,
                    "kind": "screenshot",
                    "title": "Obsolete",
                    "date": "2026-09-03T00:00:00Z",
                    "snippet": "Old",
                ]]
            )
            let provider = fixture.provider { request in
                if request.url!.path == "/api/v1/capabilities" { return (200, [:], Data(#"{"searchVersion":1}"#.utf8)) }
                return (200, [:], response)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let criteria = MeetingSearchCriteria(text: "Obsolete")
            let pending = try await MeetingRepository.serverSearch(
                vaultId: fixture.vaultId,
                criteria: criteria,
                dbQueue: fixture.queue,
                contentProvider: provider
            )
            #expect(pending.meetings.isEmpty && pending.screenshots.isEmpty)
            #expect(pending.pendingMeetings.isEmpty && pending.pendingScreenshots.isEmpty)
            try await fixture.queue.write { db in
                for _ in 0 ..< 100 {
                    try MeetingRecord(
                        id: .v7(), vaultId: fixture.vaultId, projectId: nil, name: "Newer",
                        createdAt: Date().addingTimeInterval(60), updatedAt: .now
                    ).insert(db)
                }
            }
            let capped = try await MeetingRepository.serverSearch(
                vaultId: fixture.vaultId, criteria: .init(), dbQueue: fixture.queue, contentProvider: provider
            )
            #expect(capped.pendingMeetings.count == 100 && capped.limited)
            #expect(!capped.pendingMeetings.contains { $0.id == fixture.meetingId })
            #expect(capped.meetings.isEmpty)
            try await fixture.queue.write { db in
                try db.execute(sql: "DELETE FROM sync_transactions WHERE id = ?", arguments: [transactionId])
            }
            let synced = try await MeetingRepository.serverSearch(
                vaultId: fixture.vaultId,
                criteria: criteria,
                dbQueue: fixture.queue,
                contentProvider: provider
            )
            #expect(synced.meetings.map(\.id) == [fixture.meetingId])
            #expect(synced.screenshots.map(\.id) == [imageId])
        }

        @Test
        func unknownProjectWaitsForMetadataAndCanRetry() async throws {
            let fixture = try ServerSearchFixture()
            let project = UUID.v7()
            let response = try fixture.response(meetings: [], projects: [[
                "id": project.uuidString, "projectId": project.uuidString, "kind": "project", "title": "New",
                "date": "2026-09-03T00:00:00Z", "snippet": "",
            ]])
            let provider = fixture.provider { request in
                if request.url!.path == "/api/v1/capabilities" { return (200, [:], Data(#"{"searchVersion":1}"#.utf8)) }
                return (200, [:], response)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            await #expect(throws: TextContentError.changed) {
                try await MeetingRepository.serverSearch(
                    vaultId: fixture.vaultId,
                    criteria: .init(),
                    dbQueue: fixture.queue,
                    contentProvider: provider
                )
            }
            try await fixture.queue.write { db in
                try ProjectRecord(id: project, vaultId: fixture.vaultId, path: "New", createdAt: .now).insert(db)
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'project', ?, 1)", arguments: [fixture.vaultId, project])
            }
            let result = try await MeetingRepository.serverSearch(
                vaultId: fixture.vaultId,
                criteria: .init(),
                dbQueue: fixture.queue,
                contentProvider: provider
            )
            #expect(result.projects.map(\.id) == [project])
        }

        @Test
        func rejectsOldServerTagsOfflineAndDisconnectedResponses() async throws {
            let fixture = try ServerSearchFixture()
            let supported = Mutex(false)
            let offline = Mutex(false)
            let response = try fixture.response(meetings: [])
            let provider = fixture.provider { request in
                if offline.withLock({ $0 }) { return (503, [:], Data()) }
                if request.url!.path == "/api/v1/capabilities" {
                    return (200, [:], Data((supported.withLock { $0 } ? #"{"searchVersion":1}"# : #"{}"#).utf8))
                }
                do {
                    try fixture.queue.write { db in
                        try db.execute(sql: "UPDATE vaults SET syncMutationGeneration = syncMutationGeneration + 1")
                    }
                } catch { Issue.record(error) }
                return (200, [:], response)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            await #expect(throws: TextContentError.unavailable) {
                try await provider.searchAll(vaultId: fixture.vaultId, criteria: .init(), dbQueue: fixture.queue)
            }
            await #expect(throws: TextContentError.unavailable) {
                try await provider.searchAll(vaultId: fixture.vaultId, criteria: .init(tagIDs: [1]), dbQueue: fixture.queue)
            }
            offline.withLock { $0 = true }
            await #expect(throws: (any Error).self) {
                try await provider.searchAll(vaultId: fixture.vaultId, criteria: .init(), dbQueue: fixture.queue)
            }
            offline.withLock { $0 = false }
            supported.withLock { $0 = true }
            await #expect(throws: TextContentError.changed) {
                try await provider.searchAll(vaultId: fixture.vaultId, criteria: .init(), dbQueue: fixture.queue)
            }
        }
    }

    extension ServerSearchTests {
        @Test(arguments: ["ack", "detach"])
        func rejectsSourceChangesBetweenProjectionReads(change: String) async throws {
            let fixture = try ServerSearchFixture()
            let response = try fixture.response(meetings: [[
                "id": fixture.meetingId.uuidString, "meetingId": fixture.meetingId.uuidString, "kind": "meeting",
                "title": "Server", "date": "2026-09-03T00:00:00Z", "snippet": "",
            ]])
            let provider = fixture.provider { request in
                if request.url!.path == "/api/v1/capabilities" { return (200, [:], Data(#"{"searchVersion":1}"#.utf8)) }
                return (200, [:], response)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let scheduled = Mutex(false)
            try await fixture.queue.write { db in
                try db.execute(sql: "UPDATE search_index_state SET phase = 'ready' WHERE indexKind = 'fts'")
                db.trace { event in
                    guard case let .statement(statement) = event,
                          statement.sql.contains("SELECT p.id FROM projects"),
                          scheduled.withLock({ value in if value { return false }
                              value = true
                              return true }) else { return }
                    // Queue the ACK/detach after this projection snapshot, before its next awaited read.
                    fixture.queue.asyncWriteWithoutTransaction { db in
                        do {
                            try db.inTransaction {
                                if change == "ack" {
                                    try db.execute(
                                        sql: "INSERT INTO sync_entity_state VALUES (?, 'meeting', ?, 1)",
                                        arguments: [fixture.vaultId, fixture.meetingId]
                                    )
                                    try db.execute(sql: "UPDATE vaults SET syncMutationGeneration = syncMutationGeneration + 1")
                                } else {
                                    try db.execute(sql: "UPDATE vaults SET accountConnectionId = NULL, syncConfirmedConnectionId = NULL")
                                }
                                return .commit
                            }
                        } catch { Issue.record(error) }
                    }
                }
            }
            await #expect(throws: TextContentError.changed) {
                try await MeetingRepository.serverSearch(
                    vaultId: fixture.vaultId,
                    criteria: .init(),
                    dbQueue: fixture.queue,
                    contentProvider: provider
                )
            }
            #expect(scheduled.withLock { $0 })
            if change == "ack" {
                let retried = try await MeetingRepository.serverSearch(
                    vaultId: fixture.vaultId,
                    criteria: .init(),
                    dbQueue: fixture.queue,
                    contentProvider: provider
                )
                #expect(retried.meetings.map(\.id) == [fixture.meetingId])
            }
            try await fixture.queue.write { $0.trace(nil) }
        }

        @Test
        func reportsPendingProjectOverflow() async throws {
            let fixture = try ServerSearchFixture()
            try await fixture.queue.write { db in
                try db.execute(sql: "INSERT INTO sync_entity_state VALUES (?, 'meeting', ?, 1)", arguments: [fixture.vaultId, fixture.meetingId])
                for index in 0 ..< 101 {
                    try ProjectRecord(id: .v7(), vaultId: fixture.vaultId, path: "Pending \(index)", createdAt: .now).insert(db)
                }
            }
            let response = try fixture.response(meetings: [])
            let provider = fixture.provider { request in
                if request.url!.path == "/api/v1/capabilities" { return (200, [:], Data(#"{"searchVersion":1}"#.utf8)) }
                return (200, [:], response)
            }
            defer { ImageURLProtocol.remove(origin: fixture.origin) }
            let result = try await MeetingRepository.serverSearch(
                vaultId: fixture.vaultId,
                criteria: .init(),
                dbQueue: fixture.queue,
                contentProvider: provider
            )
            #expect(result.pendingProjects.count == 100)
            #expect(result.limited)
        }
    }

    private struct ServerSearchFixture: Sendable {
        let queue: DatabaseQueue
        let vaultId = UUID.v7()
        let meetingId = UUID.v7()
        let origin = "https://search-\(UUID().uuidString.lowercased()).invalid"

        init() throws {
            queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: origin, clientID: "test", createdAt: .now)
            var vault = VaultRecord(id: vaultId, path: nil, name: "Server", createdAt: .now, lastOpenedAt: .now)
            vault.accountConnectionId = connection.id
            vault.syncConfirmedConnectionId = connection.id
            try queue.write { db in
                try connection.insert(db)
                try vault.insert(db)
                try MeetingRecord(id: meetingId, vaultId: vaultId, projectId: nil, name: "Meeting", createdAt: .now, updatedAt: .now).insert(db)
            }
        }

        func response(meetings: [[String: String]], screenshots: [[String: String]] = [], projects: [[String: String]] = []) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "vaultId": vaultId.uuidString,
                "meetings": meetings,
                "screenshots": screenshots,
                "projects": projects,
                "limited": ["meeting": false, "screenshot": false, "project": false],
            ])
        }

        func provider(handler: @escaping ImageURLProtocol.Handler) -> MeetingContentProvider {
            ImageURLProtocol.register(origin: origin, handler: handler)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ImageURLProtocol.self]
            return MeetingContentProvider(client: SyncAPIClient(
                session: URLSession(configuration: configuration),
                tokenProvider: { _, _ in "test-token" }
            ))
        }
    }
#endif
