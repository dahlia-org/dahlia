import Foundation
import GRDB
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    /// MCP ヘルパーのような別プロセスが `summaries` を書き換えたときの Summary タブ追従。
    @MainActor
    struct CaptionViewModelSummaryReloadTests {
        @Test
        func reloadPicksUpExternalSummaryChangesWithoutOverwritingTheNoteDraft() async throws {
            let context = try Self.makeContext()
            let viewModel = CaptionViewModel()
            viewModel.loadMeeting(
                context.meetingID,
                dbQueue: context.manager.dbQueue,
                projectURL: nil,
                projectId: nil,
                vaultURL: context.vaultURL
            )
            #expect(await pollUntil { viewModel.currentSummaryDocument?.title == "Original title" })

            viewModel.noteText = "Draft the user is still editing"
            try context.replaceSummary(title: "Corrected title", body: "Tanaka approved the plan")

            viewModel.reloadSummaryDocument()

            #expect(await pollUntil { viewModel.currentSummaryDocument?.title == "Corrected title" })
            #expect(viewModel.noteText == "Draft the user is still editing")
        }

        @Test
        func reloadIsIgnoredWithoutALoadedMeeting() {
            let viewModel = CaptionViewModel()
            viewModel.reloadSummaryDocument()
            #expect(viewModel.currentSummaryDocument == nil)
        }

        @Test
        func canonicalRevisionRefreshesTheOpenMeetingAndPendingStatusWithoutTouchingItsNote() async throws {
            let context = try Self.makeContext()
            defer { try? FileManager.default.removeItem(at: context.vaultURL) }
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://sync.example.test", clientID: "test", createdAt: .now)
            let vaultId = try #require(try await context.manager.dbQueue.read {
                try MeetingRecord.fetchOne($0, key: context.meetingID)?.vaultId
            })
            try await context.manager.dbQueue.write { db in
                try connection.insert(db)
                try db.execute(
                    sql: "UPDATE vaults SET accountConnectionId = ?, syncConfirmedConnectionId = ?, syncPullCursor = 'ready' WHERE id = ?",
                    arguments: [connection.id, connection.id, vaultId]
                )
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'summary', ?, 1)",
                    arguments: [vaultId, context.meetingID]
                )
            }
            let viewModel = CaptionViewModel()
            viewModel.loadMeeting(context.meetingID, dbQueue: context.manager.dbQueue, projectURL: nil, projectId: nil, vaultURL: context.vaultURL)
            #expect(await pollUntil { viewModel.currentSummaryDocument?.title == "Original title" && viewModel.meetingSyncState == .synced })
            viewModel.noteText = "Keep this local draft"
            try context.replaceSummary(title: "Canonical title", body: "Updated elsewhere")
            try await context.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE sync_entity_state SET confirmedRevision = 2 WHERE vaultId = ? AND entity = 'summary'",
                    arguments: [vaultId]
                )
                try db.execute(
                    sql: "INSERT INTO sync_transactions(id, vaultId, connectionId, createdAt, availableAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [UUID.v7(), vaultId, connection.id, Date(), Date()]
                )
            }
            #expect(await pollUntil { viewModel.currentSummaryDocument?.title == "Canonical title" && viewModel.meetingSyncState == .pending })
            #expect(viewModel.noteText == "Keep this local draft")
            try await context.manager.dbQueue.write { try SyncTransactionQueue.discard(vaultId: vaultId, in: $0) }
            #expect(await pollUntil { viewModel.meetingSyncState == .synced })
        }

        // MARK: - Helpers

        private struct Context {
            let manager: AppDatabaseManager
            let meetingID: UUID
            let vaultURL: URL

            func replaceSummary(title: String, body: String) throws {
                let document = try SummaryDocument(
                    title: title,
                    sections: [
                        SummarySection(id: .v7(), heading: "Summary", blocks: [.paragraph(body)]),
                    ]
                ).databaseJSONString()
                try manager.dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE summaries SET document = ? WHERE meetingId = ?",
                        arguments: [document, meetingID]
                    )
                }
            }
        }

        private static func makeContext() throws -> Context {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repo = MeetingRepository(dbQueue: manager.dbQueue)
            let vaultURL = URL.temporaryDirectory.appending(path: "dahlia-summary-reload-\(UUID.v7().uuidString)")
            try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

            let vault = VaultRecord(
                id: .v7(),
                path: vaultURL.path,
                name: "Test Vault",
                createdAt: Date(),
                lastOpenedAt: Date()
            )
            try repo.insertVault(vault)
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: nil,
                name: "Weekly sync",
                createdAt: Date(),
                updatedAt: Date()
            )
            let document = try SummaryDocument(
                title: "Original title",
                sections: [
                    SummarySection(id: .v7(), heading: "Summary", blocks: [.paragraph("Tanaka approved the plan")]),
                ]
            ).databaseJSONString()
            try manager.dbQueue.write { db in
                try meeting.insert(db)
                try SummaryRecord(
                    meetingId: meeting.id,
                    title: "Original title",
                    document: document,
                    createdAt: Date()
                ).insert(db)
            }

            return Context(manager: manager, meetingID: meeting.id, vaultURL: vaultURL)
        }
    }
#endif
