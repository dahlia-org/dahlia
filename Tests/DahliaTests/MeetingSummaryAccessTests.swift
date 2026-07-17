import Foundation
import GRDB
@testable import Dahlia
@testable import DahliaMeetingAccess

#if canImport(Testing)
    import Testing

    @MainActor
    struct MeetingSummaryAccessTests {
        @Test
        func invalidSummaryDocumentReturnsDedicatedError() throws {
            let fixture = try Fixture()
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE summaries SET document = 'not-json' WHERE meetingId = ?",
                    arguments: [fixture.firstMeetingID]
                )
            }

            #expect(throws: MeetingAccessError.invalidSummaryDocument) {
                try fixture.store(vaultID: fixture.primaryVaultID).meeting(id: fixture.firstMeetingID)
            }
        }

        @Test
        func summaryDocumentRequiresSectionAndBlockIDs() throws {
            let fixture = try Fixture()
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE summaries SET document = ? WHERE meetingId = ?",
                    arguments: [
                        #"""
                        {"schemaVersion":3,"title":"Invalid","sections":[
                          {"heading":"Missing IDs","blocks":[{"type":"paragraph","content":{"text":"Body"}}]}
                        ]}
                        """#,
                        fixture.firstMeetingID,
                    ]
                )
            }

            #expect(throws: MeetingAccessError.invalidSummaryDocument) {
                try fixture.store(vaultID: fixture.primaryVaultID).meeting(id: fixture.firstMeetingID)
            }
        }

        @Test
        func legacySummaryBlocksReceiveStableMCPIDs() throws {
            let fixture = try Fixture()
            let sectionID = UUID.v7()
            let document = #"""
            {"schemaVersion":2,"title":"Legacy","sections":[
              {"id":"\#(sectionID.uuidString)","heading":"Summary","blocks":[
                {"type":"paragraph","content":{"text":"Legacy body"}}
              ]}
            ]}
            """#
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE summaries SET document = ? WHERE meetingId = ?",
                    arguments: [document, fixture.firstMeetingID]
                )
            }
            let store = try fixture.store(vaultID: fixture.primaryVaultID)

            let firstID = try Self.firstSummaryBlockID(in: store.meeting(id: fixture.firstMeetingID))
            let secondID = try Self.firstSummaryBlockID(in: store.meeting(id: fixture.firstMeetingID))
            #expect(firstID == secondID)
        }

        @Test
        func legacyImageWithoutScreenshotIDFallsBackToParagraph() throws {
            let fixture = try Fixture()
            let sectionID = UUID.v7()
            let document = #"""
            {"schemaVersion":2,"title":"Legacy","sections":[
              {"id":"\#(sectionID.uuidString)","heading":"Summary","blocks":[
                {"type":"image","content":{"text":"Legacy screenshot caption","transcript_ref":"00:00:09"}}
              ]}
            ]}
            """#
            try fixture.manager.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE summaries SET document = ? WHERE meetingId = ?",
                    arguments: [document, fixture.firstMeetingID]
                )
            }

            let detail = try fixture.store(vaultID: fixture.primaryVaultID).meeting(id: fixture.firstMeetingID)
            #expect(detail.summary?.contains("Legacy screenshot caption [Transcript 00:00:09]") == true)
            guard case let .object(root)? = detail.summaryDocument,
                  case let .array(sections)? = root["sections"],
                  case let .object(section)? = sections.first,
                  case let .array(blocks)? = section["blocks"],
                  case let .object(block)? = blocks.first else {
                Issue.record("Expected a structured legacy summary document")
                return
            }
            #expect(block["type"] == .string("paragraph"))
            #expect(block["screenshot_id"] == nil)
        }

        @Test
        func storedDocumentRendererGeneratesGenericMarkdownForAllBlocks() throws {
            let captionedScreenshotID = UUID.v7()
            let emptyScreenshotID = UUID.v7()
            let document = SummaryDocument(
                title: "Release plan",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "Decision",
                        blocks: [
                            .paragraph("Ship it", transcriptRef: TranscriptReference(time: "00:00:01")),
                            .bulletedList(items: ["Alpha", "Beta"]),
                            .numberedList(items: ["First", "Second"]),
                            .checklist(items: [
                                .init(text: "Done", checked: true),
                                .init(text: "Pending", checked: false),
                            ]),
                            .quote("Quoted"),
                            .code(
                                language: "swift\n```evil",
                                code: "let value = 1\n```breakout",
                                transcriptRef: TranscriptReference(time: "00:00:02")
                            ),
                            .image(screenshotId: captionedScreenshotID, caption: "Screenshot"),
                            .image(screenshotId: emptyScreenshotID, caption: ""),
                            .heading(level: 4, text: "Details"),
                            .table(headers: ["Name", "State"], rows: [["A|B", "Ready\nNow"]]),
                        ]
                    ),
                ],
                actionItems: [SummaryActionItem(title: "Follow up", assignee: "Mina")]
            )

            let markdown = try StoredSummaryDocumentMarkdownRenderer.render(json: document.databaseJSONString())

            #expect(markdown == """
            # Release plan

            ## Decision

            Ship it [Transcript 00:00:01]

            - Alpha
            - Beta

            1. First
            2. Second

            - [x] Done
            - [ ] Pending

            > Quoted

            ````swiftevil
            let value = 1
            ```breakout
            ````

            [Transcript 00:00:02]

            [Screenshot \(captionedScreenshotID.uuidString)] Screenshot

            [Screenshot \(emptyScreenshotID.uuidString)]

            #### Details

            | Name | State |
            | --- | --- |
            | A\\|B | Ready<br>Now |

            ## Action Items
            - [ ] Follow up (Mina)
            """)
        }

        private static func firstSummaryBlockID(
            in detail: MeetingDetail
        ) throws -> DahliaMeetingAccess.JSONValue {
            guard case let .object(document)? = detail.summaryDocument,
                  case let .array(sections)? = document["sections"],
                  case let .object(section)? = sections.first,
                  case let .array(blocks)? = section["blocks"],
                  case let .object(block)? = blocks.first,
                  let id = block["id"] else {
                throw TestError.invalidJSON
            }
            return id
        }

        private enum TestError: Error {
            case invalidJSON
        }
    }
#endif
