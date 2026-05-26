import Foundation
@testable import Dahlia

#if canImport(Testing)
import Testing

@MainActor
struct SummaryServiceTests {
    @Test
    func summaryResultDecodesActionItems() throws {
        let json = """
        {
          "title": "Weekly sync",
          "summary": "Summary body",
          "tags": ["team"],
          "action_items": [
            {
              "title": "Send notes",
              "assignee": "me"
            }
          ]
        }
        """

        let result = try JSONDecoder().decode(SummaryResult.self, from: Data(json.utf8))

        #expect(result.title == "Weekly sync")
        #expect(result.actionItems == [SummaryActionItem(title: "Send notes", assignee: "me")])
    }

    @Test
    func summaryResultDefaultsActionItemsToEmpty() {
        let result = SummaryResult(title: "Title", summary: "Body", tags: ["team"])

        #expect(result.actionItems.isEmpty)
    }

    @Test
    func summaryResultSchemaRequiresActionItemsWithoutExtraFields() throws {
        let schemaData = try #require(SummaryResult.responseFormat.json_schema?.schemaData)
        let schemaObject = try JSONSerialization.jsonObject(with: schemaData)
        let schema = try #require(schemaObject as? [String: Any])
        let required = try #require(schema["required"] as? [String])
        let properties = try #require(schema["properties"] as? [String: Any])
        let actionItems = try #require(properties["action_items"] as? [String: Any])
        let items = try #require(actionItems["items"] as? [String: Any])

        #expect(required.contains("action_items"))
        #expect((items["additionalProperties"] as? Bool) == false)
    }

    @Test
    func sanitizeDisplaySummaryRemovesObsidianSyntax() {
        let input = """
        ## Summary

        - Decide to ship ([[meeting#00:10:00|00:10:00]])
        - See ![[capture-1.webp]]
        - Ref [[internal-note]]
        - ![[capture-2.webp]]
        """

        let sanitized = SummaryService.sanitizeDisplaySummary(input)

        #expect(!sanitized.contains("[["))
        #expect(!sanitized.contains("![["))
        #expect(sanitized.contains("00:10:00"))
        #expect(!sanitized.contains("internal-note"))
        #expect(!sanitized.contains("capture-2.webp"))
    }

    @Test
    func normalizeScreenshotEmbedsUsesExportedFilenameWithExtension() throws {
        let screenshotId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E6"))
        let screenshot = MeetingScreenshotRecord(
            id: screenshotId,
            meetingId: UUID(),
            capturedAt: Date(timeIntervalSince1970: 0),
            imageData: Data(),
            mimeType: "image/jpeg"
        )
        let input = """
        - Main image ![[\(screenshotId.uuidString)]]
        - Path image ![[_dahlia/screenshots/\(screenshotId.uuidString).webp|Screen]]
        - Other image ![[not-a-screenshot]]
        """

        let normalized = SummaryService.normalizeScreenshotEmbeds(input, screenshots: [screenshot])

        #expect(normalized.contains("![[\(screenshotId.uuidString).jpeg]]"))
        #expect(normalized.contains("![[_dahlia/screenshots/\(screenshotId.uuidString).jpeg|Screen]]"))
        #expect(normalized.contains("![[not-a-screenshot]]"))
        #expect(!normalized.contains("\(screenshotId.uuidString).webp"))
    }

    @Test
    func defaultSummaryPromptRequiresScreenshotFilenameExtension() {
        #expect(AppSettings.defaultSummaryPrompt.contains("![[<image_filename>]]"))
        #expect(AppSettings.defaultSummaryPrompt.contains("including its file extension"))
    }

    @Test
    func resolvedTagsDoesNotInjectAISummary() {
        let context = """
        ---
        tags:
          - customer_meeting
        ---
        """

        let tags = SummaryService.resolvedTags(
            resultTags: ["follow_up", "customer_meeting"],
            contextContent: context
        )

        #expect(tags == ["follow_up", "customer_meeting"])
        #expect(!tags.contains("ai_summary"))
    }

    @Test
    func resolvedSummaryPromptUsesDefaultWhenAutoSelected() {
        let previousInstructionID = AppSettings.shared.selectedInstructionID
        let previousVault = AppSettings.shared.currentVault
        defer {
            AppSettings.shared.selectedInstructionID = previousInstructionID
            AppSettings.shared.currentVault = previousVault
        }

        AppSettings.shared.selectedInstructionID = nil
        AppSettings.shared.currentVault = VaultRecord(
            id: .v7(),
            path: NSTemporaryDirectory(),
            name: "Test Vault",
            createdAt: Date(),
            lastOpenedAt: Date()
        )

        let prompt = SummaryService.resolvedSummaryPrompt(settings: AppSettings.shared)

        #expect(prompt == AppSettings.defaultSummaryPrompt)
    }

    @Test
    func resolvedSummaryPromptUsesSelectedInstructionFromDatabase() throws {
        let previousInstructionID = AppSettings.shared.selectedInstructionID
        let previousVault = AppSettings.shared.currentVault
        defer {
            AppSettings.shared.selectedInstructionID = previousInstructionID
            AppSettings.shared.currentVault = previousVault
        }

        let database = try AppDatabaseManager(path: ":memory:")
        let repository = MeetingRepository(dbQueue: database.dbQueue)
        let vault = VaultRecord(
            id: .v7(),
            path: NSTemporaryDirectory(),
            name: "Test Vault",
            createdAt: Date(),
            lastOpenedAt: Date()
        )
        try repository.insertVault(vault)
        let instruction = try repository.createInstruction(
            vaultId: vault.id,
            name: "customer_meeting",
            content: AppSettings.defaultSummaryPrompt + "\n\n# Extra\n- Follow up"
        )
        AppSettings.shared.currentVault = vault
        AppSettings.shared.selectedInstructionID = instruction.id

        let prompt = SummaryService.resolvedSummaryPrompt(settings: AppSettings.shared, repository: repository)

        #expect(prompt == instruction.content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

}
#endif
