import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct InstructionRepositoryTests {
        @Test
        func createUpdateDeleteAndFilterInstructionsByWorkspace() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            let firstWorkspace = WorkspaceRecord(
                id: .v7(),
                path: "/tmp/test-workspace-1",
                name: "First",
                createdAt: Date(),
                lastOpenedAt: Date()
            )
            let secondWorkspace = WorkspaceRecord(
                id: .v7(),
                path: "/tmp/test-workspace-2",
                name: "Second",
                createdAt: Date(),
                lastOpenedAt: Date()
            )
            try repository.insertWorkspace(firstWorkspace)
            try repository.insertWorkspace(secondWorkspace)

            let created = try repository.createInstruction(
                workspaceId: firstWorkspace.id,
                name: "customer_meeting",
                content: AppSettings.defaultSummaryPrompt
            )
            _ = try repository.createInstruction(
                workspaceId: secondWorkspace.id,
                name: "internal_sync",
                content: "# Output Format\n- Internal only"
            )

            #expect(try repository.fetchInstructions(workspaceId: firstWorkspace.id).map(\.id) == [created.id])
            #expect(created.content == AppSettings.defaultSummaryPrompt)

            try repository.updateInstruction(
                id: created.id,
                name: "customer_followup",
                content: "# Output Format\n- Updated"
            )

            let fetchedInstruction = try repository.fetchInstruction(id: created.id)
            let updated = try #require(fetchedInstruction)
            #expect(updated.name == "customer_followup")
            #expect(updated.content.contains("Updated"))

            try repository.deleteInstruction(id: created.id)
            #expect(try repository.fetchInstruction(id: created.id) == nil)
            #expect(try repository.fetchInstructions(workspaceId: firstWorkspace.id).isEmpty)
            #expect(try repository.fetchInstructions(workspaceId: secondWorkspace.id).count == 1)
        }
    }
#endif
