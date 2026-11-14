import DahliaMeetingAccess
import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct SummaryHistoryTests {
        @Test
        func migrationPreservesExistingSummaryAndMetadata() async throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            let prior = "v60_meetingDisplayIndexes"
            try AppDatabaseManager.schemaMigrator(for: prior).migrate(queue, upTo: prior)
            let meetingID = try seed(queue)
            let original = try document("Original", model: "old-model").databaseJSONString()
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            try await queue.write { db in
                try SummaryContent(meetingId: meetingID, title: "Original", document: original, createdAt: date).insert(db)
            }
            try AppDatabaseManager.migrator.migrate(queue)
            let page = try await SummaryHistoryService().page(meetingID: meetingID, dbQueue: queue)
            #expect(page.items.map(\.version) == [1])
            #expect(page.items.first?.savedAt == date)
            #expect(page.items.first?.metadata?.request.model == "old-model")
            let loaded = try await SummaryHistoryService().document(meetingID: meetingID, version: 1, dbQueue: queue)
            #expect(try loaded.databaseJSONString() == original)
            #expect(try await queue.read { try SummaryContent.fetchOne($0, key: meetingID)?.document } == original)
        }

        @Test
        func everyWriterRetainsVersionsWithoutDuplicatingReplays() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let queue = manager.dbQueue
            let meetingID = try seed(queue)
            let repository = MeetingRepository(dbQueue: queue)
            try repository.applyGeneratedSummary(toMeetingId: meetingID, document: document("First", model: "first-model"), tags: [])
            try repository.applyGeneratedSummary(toMeetingId: meetingID, document: document("Second", model: "second-model"), tags: [])
            let second = try #require(try repository.fetchSummary(forMeetingId: meetingID))
            try repository.upsertSummary(second)
            let corrected = try document("Corrected", model: nil).databaseJSONString()
            // The standalone MCP helper updates the body directly, outside SummaryContent.save.
            try await queue.write { db in
                try db.execute(sql: "UPDATE summary_bodies SET document = ? WHERE meetingId = ?", arguments: [corrected, meetingID])
            }
            let service = SummaryHistoryService()
            let page = try await service.page(meetingID: meetingID, dbQueue: queue)
            #expect(page.items.map(\.version) == [3, 2, 1])
            #expect(page.items.map(\.title) == ["Corrected", "Second", "First"])
            #expect(page.items.map { $0.metadata?.request.model } == [nil, "second-model", "first-model"])
            #expect(try await service.document(meetingID: meetingID, version: 1, dbQueue: queue).title == "First")
            #expect(try await queue.read { try SummaryContent.fetchOne($0, key: meetingID)?.document } == corrected)
            let history = SummaryHistoryModel()
            await history.load(meetingID: meetingID, dbQueue: queue)
            history.selectedVersion = 1
            await history.select(meetingID: meetingID, dbQueue: queue)
            #expect(history.document?.title == "First")
            history.selectedVersion = 2
            #expect(history.document == nil)
            await history.select(meetingID: meetingID, dbQueue: queue)
            #expect(history.document?.title == "Second")
            history.selectedVersion = nil
            #expect(history.document == nil)
            try await queue.write { db in
                try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [meetingID])
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM summary_versions") == 0)
            }
        }

        @Test(arguments: [false, true])
        func movingServerWorkspaceLocalRetainsCurrentBeforeNextEdit(hasPriorHistory: Bool) async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://example.test", clientID: "test", createdAt: .now)
            let meetingID = try seed(queue, connection: connection)
            try await queue.write { db in
                let meeting = try #require(try MeetingRecord.fetchOne(db, key: meetingID))
                var workspace = try #require(try WorkspaceRecord.fetchOne(db, key: meeting.workspaceId))
                if hasPriorHistory {
                    workspace.moveToLocalAccount()
                    try workspace.update(db)
                    try SummaryContent(
                        meetingId: meetingID,
                        title: "Prior local",
                        document: document("Prior local", model: nil).databaseJSONString(),
                        createdAt: .now
                    ).save(db)
                    workspace.accountConnectionId = connection.id
                    workspace.organizationId = .v7()
                    try workspace.update(db)
                }
                try SummaryContent(
                    meetingId: meetingID,
                    title: "Server current",
                    document: document("Server current", model: "server-model").databaseJSONString(),
                    createdAt: .now
                ).save(db)
                try db.inSavepoint {
                    var candidate = workspace
                    candidate.moveToLocalAccount()
                    try candidate.update(db)
                    return .rollback
                }
                #expect(try SummaryVersionRecord.filter(Column("meetingId") == meetingID).fetchCount(db) == (hasPriorHistory ? 1 : 0))
                workspace.moveToLocalAccount()
                try workspace.update(db)
                let versions = try SummaryVersionRecord.filter(Column("meetingId") == meetingID).order(Column("version")).fetchAll(db)
                #expect(versions.map(\.title) == (hasPriorHistory ? ["Prior local", "Server current"] : ["Server current"]))
                // Repeating the transition without a Server edit must not duplicate the snapshot.
                workspace.accountConnectionId = connection.id
                workspace.organizationId = .v7()
                try workspace.update(db)
                workspace.moveToLocalAccount()
                try workspace.update(db)
                try SummaryContent(
                    meetingId: meetingID,
                    title: "Local edit",
                    document: document("Local edit", model: nil).databaseJSONString(),
                    createdAt: .now
                ).save(db)
            }
            let service = SummaryHistoryService()
            let page = try await service.page(meetingID: meetingID, dbQueue: queue)
            #expect(page.items.map(\.title) == (hasPriorHistory ? ["Local edit", "Server current", "Prior local"] : ["Local edit", "Server current"]))
            let captured = try await service.document(meetingID: meetingID, version: hasPriorHistory ? 2 : 1, dbQueue: queue)
            #expect(captured.metadata?.request.model == "server-model")
        }

        @Test
        func paginationAndRollbackKeepDurableHistory() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let queue = manager.dbQueue
            let meetingID = try seed(queue)
            try await queue.write { db in
                for version in 1 ... 23 {
                    try SummaryContent(
                        meetingId: meetingID,
                        title: "v\(version)",
                        document: document("v\(version)", model: nil).databaseJSONString(),
                        createdAt: .now
                    ).save(db)
                }
            }
            struct Rollback: Error {}
            do {
                try await queue.write { db in
                    try db.execute(sql: "UPDATE summary_bodies SET document = '{}' WHERE meetingId = ?", arguments: [meetingID])
                    throw Rollback()
                }
            } catch is Rollback {}
            let service = SummaryHistoryService()
            let first = try await service.page(meetingID: meetingID, dbQueue: queue)
            let next = try await service.page(meetingID: meetingID, dbQueue: queue, before: first.nextCursor)
            #expect(first.items.map(\.version) == Array((4 ... 23).reversed()))
            #expect(next.items.map(\.version) == [3, 2, 1])
            #expect(next.nextCursor == nil)
        }

        @Test
        func serverHistoryUsesAuthenticatedAPIAndDoesNotReplaceLatest() async throws {
            let manager = try AppDatabaseManager(path: ":memory:")
            let queue = manager.dbQueue
            let origin = "https://\(UUID.v7().uuidString).example.test"
            let connectionID = UUID.v7()
            let meetingID = try seed(queue, connection: .init(id: connectionID, origin: origin, clientID: "test", createdAt: .now))
            let oldDocument = try document("Server old", model: "server-model").databaseJSONString()
            let latest = try document("Current", model: nil).databaseJSONString()
            try await queue.write { db in
                try SummaryContent(meetingId: meetingID, title: "Current", document: latest, createdAt: .now).save(db)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM summary_versions") == 0)
            }
            let record: [String: Any] = [
                "id": UUID.v7().uuidString, "meetingId": meetingID.uuidString, "version": 3, "title": "Server old",
                "createdAt": "2026-11-01T12:00:00.000Z", "savedAt": "2026-11-01T12:00:00.000Z", "document": oldDocument,
                "metadata": NSNull(),
            ]
            let page = try JSONSerialization.data(withJSONObject: ["items": [record], "nextCursor": "3"])
            let body = try JSONSerialization.data(withJSONObject: record)
            ImageURLProtocol.register(origin: origin) { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
                #expect(request.url!.path.hasPrefix("/api/v1/meetings/\(meetingID.uuidString.lowercased())/summaries"))
                if request.url!.path.hasSuffix("/3") { return (200, [:], body) }
                #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .contains(.init(name: "cursor", value: "4")) == true)
                return (200, [:], page)
            }
            defer { ImageURLProtocol.remove(origin: origin) }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ImageURLProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let service = SummaryHistoryService(client: SyncAPIClient(session: session, tokenProvider: { _, _ in "test-token" }))
            let versions = try await service.page(meetingID: meetingID, dbQueue: queue, before: "4")
            #expect(versions.items.map(\.version) == [3])
            #expect(versions.nextCursor == "3")
            #expect(try await service.document(meetingID: meetingID, version: 3, dbQueue: queue).metadata?.request.model == "server-model")
            #expect(try await queue.read { try SummaryContent.fetchOne($0, key: meetingID)?.document } == latest)
        }

        @Test
        func promotionPreservesHistoryAndMetadataAndCanBeReversed() async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let meetingID = try seed(queue)
            let original = document("First", model: "first-model")
            let current = document("Second", model: "second-model")
            let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            try await queue.write { db in
                try SummaryContent(meetingId: meetingID, title: original.title, document: original.databaseJSONString(), createdAt: createdAt)
                    .save(db)
                try SummaryContent(meetingId: meetingID, title: current.title, document: current.databaseJSONString(), createdAt: createdAt).save(db)
                try SummaryExportRecord.setURL("vault://Summary.md", meetingId: meetingID, type: .workspace, in: db)
            }
            let history = SummaryHistoryModel()
            history.selectedVersion = 1
            await history.select(meetingID: meetingID, dbQueue: queue)
            let promoted = await history.promote(meetingID: meetingID, dbQueue: queue)
            #expect(promoted == original)
            #expect(history.selectedVersion == nil)
            #expect(!history.isPromoting)
            #expect(history.error == nil)
            let service = SummaryHistoryService()
            #expect(try await service.page(meetingID: meetingID, dbQueue: queue).items.map(\.version) == [3, 2, 1])
            #expect(try await service.document(meetingID: meetingID, version: 2, dbQueue: queue) == current)
            try await queue.read { db in
                let summary = try #require(try SummaryContent.fetchOne(db, key: meetingID))
                #expect(try summary.loadDocument() == original)
                #expect(summary.title == "First")
                #expect(summary.createdAt == createdAt)
                #expect(try MeetingRecord.fetchOne(db, key: meetingID)?.name == "History")
                #expect(try SummaryExportRecord.filter(Column("meetingId") == meetingID).fetchCount(db) == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations") == 0)
            }
            _ = try await service.promote(meetingID: meetingID, document: current, dbQueue: queue)
            #expect(try await service.page(meetingID: meetingID, dbQueue: queue).items.map(\.version) == [4, 3, 2, 1])
            _ = try await service.promote(meetingID: meetingID, document: current, dbQueue: queue)
            #expect(try await service.page(meetingID: meetingID, dbQueue: queue).items.map(\.version) == [4, 3, 2, 1])
        }

        @Test
        func promotionCannotInvalidateAnExportWhileItIsBeingPublished() async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let meetingID = try seed(queue)
            let root = FileManager.default.temporaryDirectory.appending(path: UUID.v7().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let original = document("Original", model: "original-model")
            let current = document("Current", model: "current-model")
            let workspaceID = try await queue.write { db in
                let meeting = try #require(try MeetingRecord.fetchOne(db, key: meetingID))
                try db.execute(sql: "UPDATE workspaces SET path = ? WHERE id = ?", arguments: [root.path, meeting.workspaceId])
                try SummaryContent(meetingId: meetingID, title: original.title, document: original.databaseJSONString(), createdAt: .now).save(db)
                try SummaryContent(meetingId: meetingID, title: current.title, document: current.databaseJSONString(), createdAt: .now).save(db)
                return meeting.workspaceId
            }
            let request = WorkspaceSummaryExportService.LockedSummaryExportRequest(
                workspaceURL: root, workspaceID: workspaceID, meetingID: meetingID, dbQueue: queue,
                document: current, summaryFileName: "Current.md", summaryMarkdown: "Current body", isAlreadyPersisted: true
            )
            let exported = try #require(try await WorkspaceSummaryExportService.exportSummary(request) { url, markdown in
                // This callback runs after the persisted-body check while export still owns the Workspace lock.
                #expect(!Thread.isMainThread)
                #expect(throws: ProjectWorkspaceError.workspaceBusy) {
                    try MeetingRepository(dbQueue: queue).promoteSummary(meetingID: meetingID, document: original)
                }
                #expect(try queue.read { try SummaryContent.fetchOne($0, key: meetingID)?.loadDocument() } == current)
                return try WorkspaceSummaryExportService.writeSummaryFile(fileURL: url, markdown: markdown)
            })
            #expect(try await queue.read { try SummaryExportRecord.fetchOne(meetingId: meetingID, type: .workspace, in: $0) } != nil)
            _ = try await SummaryHistoryService().promote(meetingID: meetingID, document: original, dbQueue: queue)
            try await queue.read { db throws in
                #expect(try SummaryContent.fetchOne(db, key: meetingID)?.loadDocument() == original)
                #expect(try SummaryExportRecord.filter(Column("meetingId") == meetingID).fetchCount(db) == 0)
                #expect(try SummaryVersionRecord.filter(Column("meetingId") == meetingID).fetchCount(db) == 3)
            }
            #expect(try String(contentsOf: exported.fileURL, encoding: .utf8) == "Current body")
            await #expect(throws: TextContentError.changed) {
                try await WorkspaceSummaryExportService.exportSummary(request)
            }
            #expect(try await queue.read { try SummaryExportRecord.filter(Column("meetingId") == meetingID).fetchCount($0) } == 0)
        }

        @Test
        func promotionRejectsMissingCurrentAndKeepsFailedSelection() async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let meetingID = try seed(queue)
            let old = try document("Old", model: "old").databaseJSONString()
            let latest = try document("Latest", model: "latest").databaseJSONString()
            try await queue.write { db in
                try SummaryContent(meetingId: meetingID, title: "Old", document: old, createdAt: .now).save(db)
                try SummaryContent(meetingId: meetingID, title: "Latest", document: latest, createdAt: .now).save(db)
            }
            #expect(try await queue.read { try SummaryContent.fetchOne($0, key: meetingID)?.document } == latest)
            let history = SummaryHistoryModel()
            history.selectedVersion = 1
            await history.select(meetingID: meetingID, dbQueue: queue)
            try await queue.write { db in
                try db.execute(sql: "DELETE FROM summaries WHERE meetingId = ?", arguments: [meetingID])
            }
            #expect(await history.promote(meetingID: meetingID, dbQueue: queue) == nil)
            #expect(history.selectedVersion == 1)
            #expect(history.document?.title == "Old")
            #expect(history.error != nil)
            #expect(!history.isPromoting)
            #expect(try await queue.read { try SummaryContent.fetchOne($0, key: meetingID) } == nil)
        }

        @Test
        func promotionDoesNotWriteServerAccounts() async throws {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let origin = "https://\(UUID.v7().uuidString).example.test"
            let connectionID = UUID.v7()
            let meetingID = try seed(queue, connection: .init(id: connectionID, origin: origin, clientID: "test", createdAt: .now))
            let saved = document("Server old", model: "recorded-model")
            let latestJSON = try document("Latest", model: "latest").databaseJSONString()
            try await queue.write { db in
                try SummaryContent(meetingId: meetingID, title: "Latest", document: latestJSON, createdAt: .now).save(db)
            }
            let service = SummaryHistoryService()
            await #expect(throws: TextContentError.changed) {
                try await service.promote(meetingID: meetingID, document: saved, dbQueue: queue)
            }
            try await queue.read { db throws in
                #expect(try SummaryContent.fetchOne(db, key: meetingID)?.document == latestJSON)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sync_operations") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM summary_versions") == 0)
            }
        }

        private nonisolated func document(_ title: String, model: String?) -> SummaryDocument {
            SummaryDocument(title: title, sections: [], metadata: model.map {
                SummaryMetadata(
                    generatedBy: "local_codex",
                    inputTypes: ["transcript"],
                    detailLevel: "high",
                    outputLanguage: "ja",
                    request: .init(model: $0, reasoning: .init(effort: "high"))
                )
            })
        }

        private func seed(_ queue: DatabaseQueue, connection: DahliaAccountConnectionRecord? = nil) throws -> UUID {
            try queue.write { db in
                if let connection { try connection.insert(db) }
                var workspace = WorkspaceRecord(id: .v7(), path: nil, name: "History", createdAt: .now, lastOpenedAt: .now)
                workspace.accountConnectionId = connection?.id
                workspace.organizationId = connection == nil ? nil : .v7()
                workspace.syncRole = connection == nil ? nil : "admin"
                try workspace.insert(db)
                let meeting = MeetingRecord(id: .v7(), workspaceId: workspace.id, projectId: nil, name: "History", createdAt: .now, updatedAt: .now)
                try meeting.insert(db)
                return meeting.id
            }
        }
    }
#endif
