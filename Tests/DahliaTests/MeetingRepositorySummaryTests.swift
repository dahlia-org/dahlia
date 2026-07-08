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

            try context.repo.applyGeneratedSummary(
                toMeetingId: context.meeting.id,
                title: "Weekly sync",
                summary: "Summary body",
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
            #expect(result.count == 1)
            #expect(result.first?["title"] == "Legacy task")
            #expect(result.first?["assignee"] == "me")
            #expect(result.first?["isCompleted"] == true)
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
