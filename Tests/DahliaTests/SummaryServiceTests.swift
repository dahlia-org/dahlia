import Foundation
@testable import Dahlia

// swiftformat:disable indent
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
    func decodeSummaryDocumentUsesStructuredSectionsAndImages() throws {
        let screenshotId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E6"))
        let screenshot = MeetingScreenshotRecord(
            id: screenshotId,
            meetingId: UUID(),
            capturedAt: Date(timeIntervalSince1970: 0),
            imageData: Data(),
            mimeType: "image/jpeg"
        )
        let context = SummaryRenderContext(
            meetingId: screenshot.meetingId,
            createdAt: Date(timeIntervalSince1970: 0),
            screenshots: [screenshot]
        )
        let json = """
        {
          "title": "Weekly sync",
          "description": "Weekly product decisions",
          "sections": [
            {
              "heading": "Decisions",
              "blocks": [
                {
                  "type": "paragraph",
                  "level": 0,
                  "content": {"text": "Ship it", "transcript_ref": "00:10:00"},
                  "items": [],
                  "language": "",
                  "image_id": ""
                },
                {
                  "type": "image",
                  "level": 0,
                  "content": {"text": "Architecture", "transcript_ref": "00:11:00"},
                  "items": [],
                  "language": "",
                  "image_id": "\(screenshotId.uuidString)"
                }
              ]
            }
          ],
          "tags": ["team"],
          "action_items": []
        }
        """

        let document = SummaryService.decodeSummaryDocument(from: json, context: context)

        #expect(document.description == "Weekly product decisions")

        #expect(document.title == "Weekly sync")
        #expect(document.sections.first?.heading == "Decisions")
        #expect(document.sections.first?.blocks == [
            .paragraph(SummaryText("Ship it", transcriptRef: TranscriptReference(time: "00:10:00"))),
            .image(screenshotId: screenshotId, caption: SummaryText("Architecture", transcriptRef: TranscriptReference(time: "00:11:00"))),
        ])
    }

    @Test
    func decodeSummaryDocumentUsesTextLevelRefsForListItems() {
        let context = SummaryRenderContext(meetingId: UUID.v7(), createdAt: Date(timeIntervalSince1970: 0))
        let json = """
        {
          "title": "Lists",
          "description": "List rendering",
          "sections": [
            {
              "heading": "Actions",
              "blocks": [
                {
                  "type": "bulleted_list",
                  "level": 0,
                  "content": {"text": "", "transcript_ref": null},
                  "items": [
                    {"text": "Reviewed launch", "transcript_ref": "00:10:00", "checked": false},
                    {"text": "Skipped invalid timestamp", "transcript_ref": "10:00", "checked": false}
                  ],
                  "language": "",
                  "image_id": ""
                },
                {
                  "type": "checklist",
                  "level": 0,
                  "content": {"text": "", "transcript_ref": null},
                  "items": [
                    {"text": "Send notes", "transcript_ref": "00:11:00", "checked": false}
                  ],
                  "language": "",
                  "image_id": ""
                }
              ]
            }
          ],
          "tags": [],
          "action_items": []
        }
        """

        let document = SummaryService.decodeSummaryDocument(from: json, context: context)

        #expect(document.sections.first?.blocks == [
            .bulletedList(items: [
                SummaryText("Reviewed launch", transcriptRef: TranscriptReference(time: "00:10:00")),
                SummaryText("Skipped invalid timestamp"),
            ]),
            .checklist(items: [
                .init(text: SummaryText("Send notes", transcriptRef: TranscriptReference(time: "00:11:00")), checked: false),
            ]),
        ])
    }

    @Test
    func decodeSummaryDocumentPreservesCodeBodyAndExplicitRefs() {
        let context = SummaryRenderContext(meetingId: UUID.v7(), createdAt: Date(timeIntervalSince1970: 0))
        let json = """
        {
          "title": "Code",
          "description": "Code rendering",
          "sections": [
            {
              "heading": "Example",
              "blocks": [
                {
                  "type": "code",
                  "level": 0,
                  "content": {"text": "func f() {\\n    return foo()\\n}", "transcript_ref": "00:10:00"},
                  "items": [],
                  "language": "swift",
                  "image_id": ""
                }
              ]
            }
          ],
          "tags": [],
          "action_items": []
        }
        """

        let document = SummaryService.decodeSummaryDocument(from: json, context: context)

        #expect(document.sections.first?.blocks == [
            .code(
                language: "swift",
                content: SummaryText("func f() {\n    return foo()\n}", transcriptRef: TranscriptReference(time: "00:10:00"))
            ),
        ])
    }

    @Test
    func decodeSummaryDocumentSalvagesLegacyImageEmbedInStructuredParagraph() throws {
        let meetingId = UUID.v7()
        let screenshotId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E6"))
        let screenshot = MeetingScreenshotRecord(
            id: screenshotId,
            meetingId: meetingId,
            capturedAt: Date(timeIntervalSince1970: 0),
            imageData: Data(),
            mimeType: "image/jpeg"
        )
        let context = SummaryRenderContext(meetingId: meetingId, createdAt: screenshot.capturedAt, screenshots: [screenshot])
        let json = """
        {
          "title": "Image",
          "description": "Image rendering",
          "sections": [
            {
              "heading": "Summary",
              "blocks": [
                {
                  "type": "paragraph",
                  "level": 0,
                  "content": {"text": "Review ![[\(screenshotId.uuidString).jpeg|Dashboard]]", "transcript_ref": null},
                  "items": [],
                  "language": "",
                  "image_id": ""
                }
              ]
            }
          ],
          "tags": [],
          "action_items": []
        }
        """

        let document = SummaryService.decodeSummaryDocument(from: json, context: context)

        #expect(document.sections.first?.blocks == [
            .paragraph("Review"),
            .image(screenshotId: screenshotId, caption: "Dashboard"),
        ])
    }

    @Test
    func decodeSummaryDocumentFallsBackToLegacySummaryResult() {
        let context = SummaryRenderContext(meetingId: UUID.v7(), createdAt: Date(timeIntervalSince1970: 0))
        let json = """
        {
          "title": "Legacy",
          "summary": "## Summary\\n\\n- Decide ([[meeting#00:10:00|00:10:00]])",
          "tags": ["team"],
          "action_items": [
            {"title": "Follow up [[meeting#00:11:00|00:11:00]]", "assignee": "me"}
          ]
        }
        """

        let document = SummaryService.decodeSummaryDocument(from: json, context: context)

        #expect(document.title == "Legacy")
        #expect(document.tags == ["team"])
        #expect(document.sections.first?.heading == "Summary")
        #expect(document.sections.first?.blocks == [
            .bulletedList(
                items: [SummaryText("Decide", transcriptRef: TranscriptReference(time: "00:10:00"))]
            ),
        ])
        #expect(document.actionItems == [SummaryActionItem(title: "Follow up", assignee: "me")])
    }

    @Test
    func decodeSummaryDocumentDropsEmptyStructuredBlocksAndSections() {
        let context = SummaryRenderContext(meetingId: UUID.v7(), createdAt: Date(timeIntervalSince1970: 0))
        let json = """
        {
          "title": "Empty blocks",
          "description": "Empty content",
          "sections": [
            {
              "heading": "",
              "blocks": [
                {"type": "bulleted_list", "level": 0, "content": {"text": "", "transcript_ref": null}, "items": [], "language": "", "image_id": ""},
                {
                  "type": "checklist",
                  "level": 0,
                  "content": {"text": "", "transcript_ref": null},
                  "items": [{"text": "", "transcript_ref": null, "checked": false}],
                  "language": "",
                  "image_id": ""
                },
                {"type": "paragraph", "level": 0, "content": {"text": "", "transcript_ref": null}, "items": [], "language": "", "image_id": ""}
              ]
            },
            {
              "heading": "Notes",
              "blocks": [
                {"type": "numbered_list", "level": 0, "content": {"text": "", "transcript_ref": null}, "items": [], "language": "", "image_id": ""}
              ]
            }
          ],
          "tags": [],
          "action_items": []
        }
        """

        let document = SummaryService.decodeSummaryDocument(from: json, context: context)

        #expect(document.sections.count == 1)
        #expect(document.sections.first?.heading == "Notes")
        #expect(document.sections.first?.blocks.isEmpty == true)
    }

    @Test
    func screenshotMetadataUsesRelativeTimestamp() throws {
        let screenshotId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E6"))
        let timeBase = Date(timeIntervalSince1970: 1_776_384_000)
        let screenshot = MeetingScreenshotRecord(
            id: screenshotId,
            meetingId: UUID(),
            capturedAt: timeBase.addingTimeInterval(754),
            imageData: Data(),
            mimeType: "image/jpeg"
        )

        let metadata = SummaryService.screenshotMetadata(for: screenshot, relativeTo: timeBase)

        #expect(metadata.contains("<time>00:12:34</time>"))
        #expect(metadata.contains("<image_id>\(screenshotId.uuidString)</image_id>"))
        #expect(metadata.contains("<image_filename>\(screenshotId.uuidString).jpeg</image_filename>"))
    }

    @Test
    func screenshotMetadataUsesRecordingSessionOffset() {
        let sessionId = UUID.v7()
        let timeBase = Date(timeIntervalSince1970: 1_776_384_000)
        let screenshot = MeetingScreenshotRecord(
            id: UUID.v7(),
            meetingId: UUID(),
            sessionId: sessionId,
            capturedAt: timeBase.addingTimeInterval(303),
            imageData: Data(),
            mimeType: "image/jpeg"
        )

        let metadata = SummaryService.screenshotMetadata(
            for: screenshot,
            relativeTo: timeBase,
            recordingSessions: [
                RecordingSessionTimeline(
                    id: sessionId,
                    startedAt: timeBase.addingTimeInterval(300),
                    endedAt: nil,
                    offsetSeconds: 10
                ),
            ]
        )

        #expect(metadata.contains("<time>00:00:13</time>"))
    }

    @Test
    func defaultSummaryPromptRequiresStructuredImageBlocks() {
        #expect(AppSettings.defaultSummaryPrompt.contains("create an `image` block"))
        #expect(AppSettings.defaultSummaryPrompt.contains("content.transcript_ref"))
        #expect(AppSettings.defaultSummaryPrompt.contains("items[].transcript_ref"))
    }

    @Test
    func summaryPromptsKeepActionItemsOutOfBodySections() {
        #expect(AppSettings.defaultSummaryPrompt.contains("Do not add an Action Items section"))
        #expect(!AppSettings.defaultSummaryPrompt.contains("List action items if there are any"))
    }

    @Test
    func resolvedTagsDoesNotInjectAISummary() {
        let tags = SummaryService.resolvedTags(["follow_up", "customer_meeting"])

        #expect(tags == ["follow_up", "customer_meeting"])
        #expect(!tags.contains("ai_summary"))
    }

    @Test
    func resolvedTagsNormalizesObsidianIncompatibleTags() {
        let tags = SummaryService.resolvedTags([
            "customer meeting",
            "customer_meeting",
            "sales/enterprise",
            "risk:high",
            "team-check_in",
            "2026",
            "#123",
            "2026-q1",
            "!!!",
        ])

        #expect(tags == [
            "customer_meeting",
            "sales_enterprise",
            "risk_high",
            "team-check_in",
            "2026-q1",
        ])
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
// swiftformat:enable indent
