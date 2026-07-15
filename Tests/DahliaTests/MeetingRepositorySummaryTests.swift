import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MeetingRepositorySummaryTests {
        @Test
        func generatedSummaryDoesNotManageLegacyActionItems() throws {
            let context = try makeRepositoryContext()
            let legacyActionItemId = UUID.v7()

            try context.manager.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO action_items (id, meetingId, title, assignee, isCompleted)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [legacyActionItemId, context.meeting.id, "Legacy task", "me", true]
                )
            }

            let document = SummaryDocument(
                title: "Weekly sync",
                description: "Planning and launch decisions",
                sections: [
                    SummarySection(id: UUID.v7(), heading: "Summary", blocks: [.paragraph("Summary body")]),
                ],
                tags: ["team"]
            )

            try context.repo.applyGeneratedSummary(
                toMeetingId: context.meeting.id,
                document: document,
                renderedBody: "Summary body",
                tags: ["team"]
            )

            let result = try context.manager.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: "SELECT title, assignee, isCompleted FROM action_items WHERE meetingId = ?",
                    arguments: [context.meeting.id]
                )
            }
            let fetchedSummary = try context.repo.fetchSummary(forMeetingId: context.meeting.id)
            let summary = try #require(fetchedSummary)

            #expect(summary.summary == "Summary body")
            #expect(summary.loadDocument() == document)
            let meeting = try #require(try context.repo.fetchMeeting(id: context.meeting.id))
            #expect(meeting.name == "Weekly sync")
            #expect(meeting.description == "Planning and launch decisions")
            #expect(result.count == 1)
            #expect(result.first?["title"] == "Legacy task")
            #expect(result.first?["assignee"] == "me")
            #expect(result.first?["isCompleted"] == true)
        }

        @Test
        func legacySummaryRecordLoadsDocumentFromMarkdownFallback() {
            let record = SummaryRecord(
                meetingId: UUID.v7(),
                title: "Legacy",
                summary: "## Summary\n\n- Decide [[meeting#00:10:00|00:10:00]]",
                document: nil,
                vaultRelativePath: nil,
                googleFileId: nil,
                createdAt: Date()
            )

            let document = record.loadDocument()

            #expect(document.title == "Legacy")
            #expect(document.sections.first?.heading == "Summary")
            #expect(document.sections.first?.blocks == [
                .bulletedList(
                    items: [SummaryText("Decide", transcriptRef: TranscriptReference(time: "00:10:00"))]
                ),
            ])
        }

        @Test
        func regeneratingSummaryClearsStaleExportLocations() throws {
            let context = try makeRepositoryContext()
            try context.repo.upsertSummary(
                SummaryRecord(
                    meetingId: context.meeting.id,
                    title: "Old",
                    summary: "Old body",
                    vaultRelativePath: "Acme/Existing.md",
                    googleFileId: "old-google-file",
                    createdAt: .now
                )
            )
            let document = SummaryDocument(
                title: "Updated",
                sections: [SummarySection(id: .v7(), heading: "Summary", blocks: [.paragraph("New body")])],
                tags: []
            )

            try context.repo.applyGeneratedSummary(
                toMeetingId: context.meeting.id,
                document: document,
                renderedBody: "New body",
                tags: []
            )

            let fetchedSummary = try context.repo.fetchSummary(forMeetingId: context.meeting.id)
            let summary = try #require(fetchedSummary)
            #expect(summary.vaultRelativePath == nil)
            #expect(summary.googleFileId == nil)
            #expect(try context.repo.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .vault
            ) == nil)
            #expect(try context.repo.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .googleDocs
            ) == nil)
        }

        @Test
        func storesVaultAndGoogleDocsExportsIndependently() throws {
            let context = try makeRepositoryContext()
            try context.repo.upsertSummary(
                SummaryRecord(
                    meetingId: context.meeting.id,
                    title: "Summary",
                    summary: "Body",
                    vaultRelativePath: nil,
                    googleFileId: nil,
                    createdAt: .now
                )
            )

            try context.repo.updateSummaryVaultRelativePath(
                forMeetingId: context.meeting.id,
                relativePath: "Acme/Summary.md"
            )
            try context.repo.updateSummaryGoogleFileId(
                forMeetingId: context.meeting.id,
                googleFileId: "google-123"
            )

            let vault = try context.repo.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .vault
            )
            let googleDocs = try context.repo.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .googleDocs
            )

            #expect(vault?.url == "vault:///Acme/Summary.md")
            #expect(vault?.vaultRelativePath == "Acme/Summary.md")
            #expect(googleDocs?.url == "https://docs.google.com/document/d/google-123/edit")

            try context.repo.updateSummaryVaultRelativePath(
                forMeetingId: context.meeting.id,
                relativePath: nil
            )

            #expect(try context.repo.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .vault
            ) == nil)
            #expect(try context.repo.fetchSummaryExport(
                forMeetingId: context.meeting.id,
                type: .googleDocs
            )?.googleDocumentID == "google-123")
        }

        @Test
        func regeneratingSummaryUpdatesMeetingMetadataAndKeepsNameForBlankTitle() throws {
            let context = try makeRepositoryContext()
            try context.repo.applyGeneratedSummary(
                toMeetingId: context.meeting.id,
                document: SummaryDocument(
                    title: "Renamed\nby AI",
                    description: "First description",
                    sections: []
                ),
                renderedBody: "First",
                tags: []
            )
            try context.repo.applyGeneratedSummary(
                toMeetingId: context.meeting.id,
                document: SummaryDocument(
                    title: "  ",
                    description: "  ",
                    sections: []
                ),
                renderedBody: "Second",
                tags: []
            )

            let meeting = try #require(try context.repo.fetchMeeting(id: context.meeting.id))
            #expect(meeting.name == "Renamed by AI")
            #expect(meeting.description == "First description")
        }

        private func makeRepositoryContext() throws -> RepositoryContext {
            let manager = try AppDatabaseManager(path: ":memory:")
            let repo = MeetingRepository(dbQueue: manager.dbQueue)

            let vault = VaultRecord(
                id: .v7(),
                path: "/tmp/test-vault",
                name: "Test Vault",
                createdAt: Date(),
                lastOpenedAt: Date()
            )
            try repo.insertVault(vault)

            let project = try repo.fetchOrCreateProject(name: "Acme", vaultId: vault.id)

            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: project.id,
                name: "Weekly sync",
                createdAt: Date(),
                updatedAt: Date()
            )
            try manager.dbQueue.write { db in
                try meeting.insert(db)
            }

            return RepositoryContext(manager: manager, repo: repo, vault: vault, project: project, meeting: meeting)
        }

        private struct RepositoryContext {
            let manager: AppDatabaseManager
            let repo: MeetingRepository
            let vault: VaultRecord
            let project: ProjectRecord
            let meeting: MeetingRecord
        }
    }
#endif
