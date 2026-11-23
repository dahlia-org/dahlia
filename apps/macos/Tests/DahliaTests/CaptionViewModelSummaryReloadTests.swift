import DahliaMeetingAccess
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
                workspaceURL: context.workspaceURL
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
        func promotionUpdatesOnlyTheMatchingMeetingAndPreservesTheNoteDraft() async throws {
            let context = try Self.makeContext()
            defer { try? FileManager.default.removeItem(at: context.workspaceURL) }
            let viewModel = CaptionViewModel()
            defer { viewModel.clearCurrentMeeting() }
            viewModel.loadMeeting(
                context.meetingID, dbQueue: context.manager.dbQueue, projectURL: nil, projectId: nil, workspaceURL: context.workspaceURL
            )
            #expect(await pollUntil { viewModel.currentSummaryDocument?.title == "Original title" })
            viewModel.noteText = "Keep this draft"
            viewModel.currentSummaryGoogleFileId = "stale-export"
            viewModel.lastSummaryURL = context.workspaceURL.appending(path: "old.md")
            let promoted = SummaryDocument(title: "Promoted", sections: [])
            viewModel.applyPromotedSummary(promoted, meetingID: .v7())
            #expect(viewModel.currentSummaryDocument?.title == "Original title")
            viewModel.applyPromotedSummary(promoted, meetingID: context.meetingID)
            #expect(viewModel.currentSummaryDocument == promoted)
            #expect(viewModel.currentSummaryGoogleFileId == nil)
            #expect(viewModel.lastSummaryURL == nil)
            #expect(viewModel.noteText == "Keep this draft")
        }

        // MARK: - Helpers

        private struct Context {
            let manager: AppDatabaseManager
            let meetingID: UUID
            let workspaceURL: URL

            func replaceSummary(title: String, body: String) throws {
                let document = try SummaryDocument(
                    title: title,
                    sections: [
                        SummarySection(id: .v7(), heading: "Summary", blocks: [.paragraph(body)]),
                    ]
                ).databaseJSONString()
                try manager.dbQueue.write { db in
                    try db.execute(
                        sql: "UPDATE summary_bodies SET document = ? WHERE meetingId = ?",
                        arguments: [document, meetingID]
                    )
                }
            }
        }

        private static func makeContext() throws -> Context {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repo = MeetingRepository(dbQueue: manager.dbQueue)
            let workspaceURL = URL.temporaryDirectory.appending(path: "dahlia-summary-reload-\(UUID.v7().uuidString)")
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

            let workspace = WorkspaceRecord(
                id: .v7(),
                path: workspaceURL.path,
                name: "Test Workspace",
                createdAt: Date(),
                lastOpenedAt: Date()
            )
            try repo.insertWorkspace(workspace)
            let meeting = MeetingRecord(
                id: .v7(),
                workspaceId: workspace.id,
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
                try SummaryContent(
                    meetingId: meeting.id,
                    title: "Original title",
                    document: document,
                    createdAt: Date()
                ).insert(db)
            }

            return Context(manager: manager, meetingID: meeting.id, workspaceURL: workspaceURL)
        }
    }
#endif
