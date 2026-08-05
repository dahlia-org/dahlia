import Foundation
@testable import Dahlia
@testable import DahliaRuntimeSupport

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
                  "image_id": "",
                  "columns": [],
                  "rows": []
                },
                {
                  "type": "image",
                  "level": 0,
                  "content": {"text": "Architecture", "transcript_ref": "00:11:00"},
                  "items": [],
                  "language": "",
                  "image_id": "\(screenshotId.uuidString)",
                  "columns": [],
                  "rows": []
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
                    {"text": "Reviewed launch", "transcript_ref": "00:10:00", "checked": false, "indent": 0},
                    {"text": "Skipped invalid timestamp", "transcript_ref": "10:00", "checked": false, "indent": 1}
                  ],
                  "language": "",
                  "image_id": "",
                  "columns": [],
                  "rows": []
                },
                {
                  "type": "checklist",
                  "level": 0,
                  "content": {"text": "", "transcript_ref": null},
                  "items": [
                    {"text": "Send notes", "transcript_ref": "00:11:00", "checked": false, "indent": 0}
                  ],
                  "language": "",
                  "image_id": "",
                  "columns": [],
                  "rows": []
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
                SummaryListItem(
                    text: SummaryText("Reviewed launch", transcriptRef: TranscriptReference(time: "00:10:00"))
                ),
                SummaryListItem(text: "Skipped invalid timestamp", indent: 1),
            ]),
            .checklist(items: [
                .init(text: SummaryText("Send notes", transcriptRef: TranscriptReference(time: "00:11:00")), checked: false),
            ]),
        ])
    }

    @Test
    func decodeSummaryDocumentNormalizesListIndentAfterDroppingBlankItems() throws {
        let context = SummaryRenderContext(meetingId: UUID.v7(), createdAt: Date(timeIntervalSince1970: 0))
        let json = """
        {
          "title": "Lists",
          "description": "Indent normalization",
          "sections": [
            {
              "heading": "Hierarchy",
              "blocks": [
                {
                  "type": "numbered_list",
                  "level": 0,
                  "content": {"text": "", "transcript_ref": null},
                  "items": [
                    {"text": "  ", "transcript_ref": null, "checked": false, "indent": 0},
                    {"text": "Root", "transcript_ref": null, "checked": false, "indent": 2},
                    {"text": "Child", "transcript_ref": null, "checked": false, "indent": 2},
                    {"text": "Grandchild", "transcript_ref": null, "checked": false, "indent": 8},
                    {"text": "Root two", "transcript_ref": null, "checked": false, "indent": 0},
                    {"text": "Clamped low", "transcript_ref": null, "checked": false, "indent": -1}
                  ],
                  "language": "",
                  "image_id": "",
                  "columns": [],
                  "rows": []
                }
              ]
            }
          ],
          "tags": [],
          "action_items": []
        }
        """

        let document = SummaryService.decodeSummaryDocument(from: json, context: context)
        let block = try #require(document.sections.first?.blocks.first)
        guard case let .numberedList(items) = block.content else {
            Issue.record("Expected a numbered list")
            return
        }

        #expect(items.map(\.text.text) == ["Root", "Child", "Grandchild", "Root two", "Clamped low"])
        #expect(items.map(\.indent) == [0, 1, 2, 0, 0])
    }

    @Test
    func decodeSummaryDocumentNormalizesTablesWithinDocumentCellBudget() throws {
        let columns = (0..<13).map { "Column \($0)" }
        var rows = (0..<51).map { row in
            (0..<13).map { column in "R\(row)C\(column)" }
        }
        rows[0] = ["Short"]
        let table: [String: Any] = [
            "type": "table",
            "level": 0,
            "content": ["text": "", "transcript_ref": NSNull()],
            "items": [],
            "language": "",
            "image_id": "",
            "columns": columns,
            "rows": rows,
        ]
        let response: [String: Any] = [
            "title": "Tables",
            "description": "Budget",
            "sections": [["heading": "Data", "blocks": [table, table, table]]],
            "tags": [],
            "action_items": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        let context = SummaryRenderContext(meetingId: UUID.v7(), createdAt: Date(timeIntervalSince1970: 0))

        let document = SummaryService.decodeSummaryDocument(
            from: String(decoding: data, as: UTF8.self),
            context: context
        )
        let tables = document.sections[0].blocks.compactMap { block -> (headers: [SummaryText], rows: [[SummaryText]])? in
            guard case let .table(headers, rows) = block.content else { return nil }
            return (headers, rows)
        }

        #expect(document.schemaVersion == 4)
        #expect(tables.count == 2)
        #expect(tables[0].headers.count == 12)
        #expect(tables[0].rows.count == 50)
        #expect(tables[0].rows[0].map(\.text) == ["Short"] + Array(repeating: "", count: 11))
        #expect(tables[1].headers.count == 12)
        #expect(tables[1].rows.count == 48)
        #expect(tables.flatMap(\.rows).allSatisfy { $0.count == 12 })
        #expect(tables.flatMap(\.headers).allSatisfy { $0.transcriptRef == nil })
        #expect(tables.flatMap(\.rows).flatMap { $0 }.allSatisfy { $0.transcriptRef == nil })
        let cellCount = tables.reduce(0) { count, table in
            count + table.headers.count + table.rows.reduce(0) { $0 + $1.count }
        }
        #expect(cellCount == 1200)
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
                  "image_id": "",
                  "columns": [],
                  "rows": []
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
                  "image_id": "",
                  "columns": [],
                  "rows": []
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
                {"type": "bulleted_list", "level": 0, "content": {"text": "", "transcript_ref": null}, "items": [], "language": "", "image_id": "", "columns": [], "rows": []},
                {
                  "type": "checklist",
                  "level": 0,
                  "content": {"text": "", "transcript_ref": null},
                  "items": [{"text": "", "transcript_ref": null, "checked": false, "indent": 1}],
                  "language": "",
                  "image_id": "",
                  "columns": [],
                  "rows": []
                },
                {"type": "paragraph", "level": 0, "content": {"text": "", "transcript_ref": null}, "items": [], "language": "", "image_id": "", "columns": [], "rows": []}
              ]
            },
            {
              "heading": "Notes",
              "blocks": [
                {"type": "numbered_list", "level": 0, "content": {"text": "", "transcript_ref": null}, "items": [], "language": "", "image_id": "", "columns": [], "rows": []}
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
        #expect(AppSettings.defaultSummaryPrompt.contains("items[].indent"))
        #expect(AppSettings.defaultSummaryPrompt.contains("Use a table for comparisons and mappings"))
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
            "Customer Meeting",
            "customer_meeting",
            "sales/Enterprise",
            "risk:HIGH",
            "team-check_in",
            "2026",
            "#123",
            "2026-Q1",
            "日本語",
            "Ｆｕｌｌ１２３",
            "!!!",
        ])

        #expect(tags == [
            "customer_meeting",
            "sales_enterprise",
            "risk_high",
            "team_check_in",
            "2026_q1",
        ])
    }

    @Test
    func structuredPromptRequiresLowercaseASCIITags() {
        #expect(SummaryService.codexStructuredInstruction.contains("lowercase ASCII letters (a-z), ASCII numbers (0-9), and \"_\""))
        #expect(!SummaryService.codexStructuredInstruction.contains("and \"-\""))
        #expect(SummaryService.codexStructuredInstruction.contains("and \"indent\" as 0, 1, or 2"))
        #expect(SummaryService.codexStructuredInstruction.contains("\"columns\": table header strings"))
        #expect(SummaryService.codexStructuredInstruction.contains("\"rows\": table body rows"))
    }

    @Test
    func summaryDetailLevelFallsBackToDetailed() {
        let previousValue = AppSettings.shared.summaryDetailLevelRawValue
        defer { AppSettings.shared.summaryDetailLevelRawValue = previousValue }

        #expect(SummaryDetailLevel.defaultValue == .detailed)
        for detailLevel in SummaryDetailLevel.allCases {
            AppSettings.shared.summaryDetailLevelRawValue = detailLevel.rawValue
            #expect(AppSettings.shared.summaryDetailLevel == detailLevel)
        }

        AppSettings.shared.summaryDetailLevelRawValue = "unsupported"
        #expect(AppSettings.shared.summaryDetailLevel == .detailed)
    }

    @Test
    func summaryGenerationInstructionsIncludeDetailAndLanguage() {
        let settings = AppSettings.shared
        let previousDetailLevel = settings.summaryDetailLevelRawValue
        let previousLanguage = settings.llmSummaryLanguageRawValue
        defer {
            settings.summaryDetailLevelRawValue = previousDetailLevel
            settings.llmSummaryLanguageRawValue = previousLanguage
        }

        settings.llmSummaryLanguage = .en
        for detailLevel in SummaryDetailLevel.allCases {
            settings.summaryDetailLevel = detailLevel
            let instructions = SummaryService.summaryGenerationInstructions(
                settings: settings,
                includesPreviousMeetings: false
            )

            #expect(instructions.hasPrefix(AppSettings.defaultSummaryPrompt))
            #expect(instructions.contains(detailLevel.instruction))
            #expect(instructions.contains("Write the summary in English."))
        }
    }

    @Test
    func summaryGenerationInstructionsIgnoreSelectedCustomInstruction() {
        let previousInstructionID = AppSettings.shared.selectedInstructionID
        defer { AppSettings.shared.selectedInstructionID = previousInstructionID }

        let settings = AppSettings.shared
        settings.selectedInstructionID = nil
        let autoInstructions = SummaryService.summaryGenerationInstructions(
            settings: settings,
            includesPreviousMeetings: false
        )
        settings.selectedInstructionID = .v7()
        let selectedInstructions = SummaryService.summaryGenerationInstructions(
            settings: settings,
            includesPreviousMeetings: false
        )

        #expect(selectedInstructions == autoInstructions)
    }

    @Test
    func summaryGenerationInstructionsIncludePreviousMeetingsOnlyWhenRequested() {
        let withoutPreviousMeetings = SummaryService.summaryGenerationInstructions(
            settings: AppSettings.shared,
            includesPreviousMeetings: false
        )
        let withPreviousMeetings = SummaryService.summaryGenerationInstructions(
            settings: AppSettings.shared,
            includesPreviousMeetings: true
        )

        #expect(!withoutPreviousMeetings.contains(SummaryService.codexPreviousMeetingsInstruction))
        #expect(withPreviousMeetings.components(separatedBy: SummaryService.codexPreviousMeetingsInstruction).count == 2)
    }

}
#endif
// swiftformat:enable indent
