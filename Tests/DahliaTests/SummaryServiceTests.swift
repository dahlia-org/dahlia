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
                    {"text": "Skipped invalid timestamp", "transcript_ref": "10:00", "checked": false, "indent": 0}
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
                  "items": [{"text": "", "transcript_ref": null, "checked": false, "indent": 0}],
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
    func decodeSummaryDocumentNormalizesListIndentAfterDroppingBlankItems() {
        let context = SummaryRenderContext(meetingId: .v7(), createdAt: .now)
        let json = """
        {
          "title": "Lists",
          "description": "Hierarchy",
          "sections": [{
            "heading": "Items",
            "blocks": [{
              "type": "bulleted_list",
              "level": 0,
              "content": {"text": "", "transcript_ref": null},
              "items": [
                {"text": "Parent", "transcript_ref": null, "checked": false, "indent": 0},
                {"text": "   ", "transcript_ref": null, "checked": false, "indent": 1},
                {"text": "Child", "transcript_ref": null, "checked": false, "indent": 2}
              ],
              "language": "",
              "image_id": "",
              "columns": [],
              "rows": []
            }]
          }],
          "tags": [],
          "action_items": []
        }
        """

        let document = SummaryService.decodeSummaryDocument(from: json, context: context)

        #expect(document.sections[0].blocks == [
            .bulletedList(items: [
                SummaryListItem(text: "Parent", indent: 0),
                SummaryListItem(text: "Child", indent: 1),
            ]),
        ])
    }

    @Test
    func decodeSummaryDocumentClampsAndRepairsListIndentJumps() {
        let context = SummaryRenderContext(meetingId: .v7(), createdAt: .now)
        let itemJSON = zip(["A", "B", "C", "D", "E"], [2, 0, 2, 2, 7]).map { text, indent in
            "{\"text\":\"\(text)\",\"transcript_ref\":null,\"checked\":false,\"indent\":\(indent)}"
        }
        .joined(separator: ",")
        let json = """
        {
          "title": "Lists",
          "description": "Hierarchy",
          "sections": [{
            "heading": "Items",
            "blocks": [{
              "type": "numbered_list",
              "level": 0,
              "content": {"text": "", "transcript_ref": null},
              "items": [\(itemJSON)],
              "language": "",
              "image_id": "",
              "columns": [],
              "rows": []
            }]
          }],
          "tags": [],
          "action_items": []
        }
        """

        let document = SummaryService.decodeSummaryDocument(from: json, context: context)
        guard case let .numberedList(items) = document.sections[0].blocks[0].content else {
            Issue.record("Expected a numbered list")
            return
        }

        #expect(items.map(\.indent) == [0, 0, 1, 2, 2])
    }

    @Test
    func decodeSummaryDocumentBoundsGeneratedTablesPerBlockAndDocument() throws {
        let context = SummaryRenderContext(meetingId: .v7(), createdAt: .now)
        let columns = (0 ..< 13).map { index in
            index == 0 ? "Header [[meeting#00:00:01|00:00:01]]" : "Header \(index)"
        }
        let rows = (0 ..< 51).map { row in
            (0 ..< 13).map { column in
                row == 0 && column == 0 ? "Cell [[meeting#00:00:02|00:00:02]]" : "R\(row)C\(column)"
            }
        }
        func tableBlock(columns: [String], rows: [[String]]) -> [String: Any] {
            [
                "type": "table",
                "level": 0,
                "content": ["text": "", "transcript_ref": NSNull()],
                "items": [],
                "language": "",
                "image_id": "",
                "columns": columns,
                "rows": rows,
            ]
        }
        let response: [String: Any] = [
            "title": "Tables",
            "description": "Bounded tables",
            "sections": [
                ["heading": "First", "blocks": [tableBlock(columns: columns, rows: rows)]],
                [
                    "heading": "Second",
                    "blocks": [
                        tableBlock(columns: Array(columns.prefix(12)), rows: rows),
                        tableBlock(columns: ["Discarded"], rows: []),
                    ],
                ],
            ],
            "tags": [],
            "action_items": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        let json = String(decoding: data, as: UTF8.self)

        let document = SummaryService.decodeSummaryDocument(from: json, context: context)
        let tables = document.sections.flatMap(\.blocks).compactMap { block -> (headers: [SummaryText], rows: [[SummaryText]])? in
            guard case let .table(headers, rows) = block.content else { return nil }
            return (headers, rows)
        }

        #expect(document.schemaVersion == SummaryDocumentSchemaVersion.current)
        #expect(tables.count == 2)
        #expect(tables[0].headers.count == 12)
        #expect(tables[0].rows.count == 50)
        #expect(tables[0].headers.count * (1 + tables[0].rows.count) == 612)
        #expect(tables[1].headers.count == 12)
        #expect(tables[1].rows.count == 48)
        #expect(tables[1].headers.count * (1 + tables[1].rows.count) == 588)
        #expect(tables.flatMap { $0.headers + $0.rows.flatMap { $0 } }.allSatisfy { $0.transcriptRef == nil })
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
    func summaryPromptsGuideListHierarchyAndTables() throws {
        let guidance = "Use `items[].indent` only when list items have a clear parent/child relationship."
        #expect(AppSettings.defaultSummaryPrompt.contains(guidance))
        #expect(AppSettings.defaultSummaryPrompt.contains("Do not nest items merely for emphasis"))
        #expect(AppSettings.defaultSummaryPrompt.contains("Use a table for clear comparisons or mappings"))
        #expect(AppSettings.defaultSummaryPrompt.contains("Never put transcript links or `transcript_ref` objects in table cells"))

        #expect(SummaryService.codexStructuredInstruction.contains("\"table\""))
        #expect(SummaryService.codexStructuredInstruction.contains("\"columns\""))
        #expect(SummaryService.codexStructuredInstruction.contains("\"rows\""))
        #expect(SummaryService.codexStructuredInstruction.contains("\"indent\" as 0, 1, or 2"))
        #expect(!SummaryService.codexStructuredInstruction.contains("Do not output tables"))

        let customerFormat = try #require(AppSettings.presetTemplates["customer_meeting"])
        let sharedPreamble = try #require(AppSettings.defaultSummaryPrompt.components(separatedBy: "# Output Format").first)
        let customerPrompt = sharedPreamble + customerFormat
        #expect(customerPrompt.contains(guidance))
        #expect(customerPrompt.contains("### 次のステップ"))
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
