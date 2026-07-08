import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

@MainActor
struct InstructionRepositoryTests {
    @Test
    func createUpdateDeleteAndFilterInstructionsByVault() throws {
        let database = try AppDatabaseManager(path: ":memory:")
        let repository = MeetingRepository(dbQueue: database.dbQueue)
        let firstVault = VaultRecord(
            id: .v7(),
            path: "/tmp/test-vault-1",
            name: "First",
            createdAt: Date(),
            lastOpenedAt: Date()
        )
        let secondVault = VaultRecord(
            id: .v7(),
            path: "/tmp/test-vault-2",
            name: "Second",
            createdAt: Date(),
            lastOpenedAt: Date()
        )
        try repository.insertVault(firstVault)
        try repository.insertVault(secondVault)

        let created = try repository.createInstruction(
            vaultId: firstVault.id,
            name: "customer_meeting",
            content: AppSettings.defaultSummaryPrompt
        )
        _ = try repository.createInstruction(
            vaultId: secondVault.id,
            name: "internal_sync",
            content: "# Output Format\n- Internal only"
        )

        #expect(try repository.fetchInstructions(vaultId: firstVault.id).map(\.id) == [created.id])
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
        #expect(try repository.fetchInstructions(vaultId: firstVault.id).isEmpty)
        #expect(try repository.fetchInstructions(vaultId: secondVault.id).count == 1)
    }
}
#elseif canImport(XCTest)
import XCTest

@MainActor
final class InstructionRepositoryTests: XCTestCase {
    func testCreateUpdateDeleteAndFilterInstructionsByVault() throws {
        let database = try AppDatabaseManager(path: ":memory:")
        let repository = MeetingRepository(dbQueue: database.dbQueue)
        let firstVault = VaultRecord(
            id: .v7(),
            path: "/tmp/test-vault-1",
            name: "First",
            createdAt: Date(),
            lastOpenedAt: Date()
        )
        let secondVault = VaultRecord(
            id: .v7(),
            path: "/tmp/test-vault-2",
            name: "Second",
            createdAt: Date(),
            lastOpenedAt: Date()
        )
        try repository.insertVault(firstVault)
        try repository.insertVault(secondVault)

        let created = try repository.createInstruction(
            vaultId: firstVault.id,
            name: "customer_meeting",
            content: AppSettings.defaultSummaryPrompt
        )
        _ = try repository.createInstruction(
            vaultId: secondVault.id,
            name: "internal_sync",
            content: "# Output Format\n- Internal only"
        )

        XCTAssertEqual(try repository.fetchInstructions(vaultId: firstVault.id).map(\.id), [created.id])
        XCTAssertEqual(created.content, AppSettings.defaultSummaryPrompt)

        try repository.updateInstruction(
            id: created.id,
            name: "customer_followup",
            content: "# Output Format\n- Updated"
        )

        let updated = try XCTUnwrap(repository.fetchInstruction(id: created.id))
        XCTAssertEqual(updated.name, "customer_followup")
        XCTAssertTrue(updated.content.contains("Updated"))

        try repository.deleteInstruction(id: created.id)
        XCTAssertNil(try repository.fetchInstruction(id: created.id))
        XCTAssertTrue(try repository.fetchInstructions(vaultId: firstVault.id).isEmpty)
        XCTAssertEqual(try repository.fetchInstructions(vaultId: secondVault.id).count, 1)
    }
}
#endif
