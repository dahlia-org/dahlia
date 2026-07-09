import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct LegacyMarkdownSummaryParserTests {
        @Test
        func parsesFrontmatterSectionsLegacyLinksImagesChecklistAndTable() throws {
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
            let markdown = """
            ---
            meeting_id: "\(meetingId.uuidString)"
            date: 2026-07-09
            ---

            ## Summary

            Decide to ship ([[\(meetingId.uuidString)#00:10:00|00:10:00]]) and see ![[_dahlia/screenshots/\(screenshotId.uuidString).webp|Screen]]

            - [x] Send notes
            - [ ] Confirm date

            | Topic | Owner |
            | --- | --- |
            | Launch | Team |

            ## Risks

            > Timing is tight
            """

            let document = LegacyMarkdownSummaryParser.parse(markdown: markdown, title: "Weekly sync", context: context)

            #expect(document.title == "Weekly sync")
            #expect(document.sections.count == 2)
            #expect(document.sections[0].heading == "Summary")
            #expect(document.sections[0].blocks == [
                .paragraph(
                    SummaryText("Decide to ship and see", transcriptRef: TranscriptReference(time: "00:10:00"))
                ),
                .image(screenshotId: screenshotId, caption: "Screen"),
                .checklist(items: [
                    .init(text: "Send notes", checked: true),
                    .init(text: "Confirm date", checked: false),
                ]),
                .table(headers: ["Topic", "Owner"], rows: [["Launch", "Team"]]),
            ])
            #expect(document.sections[1].heading == "Risks")
            #expect(document.sections[1].blocks == [.quote("Timing is tight")])
        }

        @Test
        func preservesImagesInListQuoteHeadingAndTableCells() throws {
            let meetingId = UUID.v7()
            let listImageId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E6"))
            let quoteImageId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E7"))
            let headingImageId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E8"))
            let tableImageId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E9"))
            let screenshots = [listImageId, quoteImageId, headingImageId, tableImageId].map { id in
                MeetingScreenshotRecord(
                    id: id,
                    meetingId: meetingId,
                    capturedAt: Date(timeIntervalSince1970: 0),
                    imageData: Data(),
                    mimeType: "image/jpeg"
                )
            }
            let context = SummaryRenderContext(meetingId: meetingId, createdAt: Date(timeIntervalSince1970: 0), screenshots: screenshots)
            let markdown = """
            ## Summary

            - Reviewed ![[\(listImageId.uuidString).jpeg|List image]]

            > Quote ![[\(quoteImageId.uuidString).jpeg|Quote image]]

            ### Heading ![[\(headingImageId.uuidString).jpeg|Heading image]]

            | Topic |
            | --- |
            | Cell ![[\(tableImageId.uuidString).jpeg|Table image]] |
            """

            let document = LegacyMarkdownSummaryParser.parse(markdown: markdown, title: "Images", context: context)

            #expect(document.sections.first?.blocks == [
                .bulletedList(items: ["Reviewed"]),
                .image(screenshotId: listImageId, caption: "List image"),
                .quote("Quote"),
                .image(screenshotId: quoteImageId, caption: "Quote image"),
                .heading(level: 3, text: "Heading"),
                .image(screenshotId: headingImageId, caption: "Heading image"),
                .table(headers: ["Topic"], rows: [["Cell"]]),
                .image(screenshotId: tableImageId, caption: "Table image"),
            ])
        }

        @Test
        func keepsAliaslessWikiLinkText() {
            let document = LegacyMarkdownSummaryParser.parse(
                markdown: "## Summary\n\nSee [[Project Alpha]] for details",
                title: "Wiki"
            )

            #expect(document.sections.first?.blocks == [.paragraph("See Project Alpha for details")])
        }

        @Test
        func keepsTranscriptReferencesOnEachListItem() {
            let meetingId = UUID.v7()
            let markdown = """
            ## Summary

            - Decide [[\(meetingId.uuidString)#00:10:00|00:10:00]]
            - Follow up [[\(meetingId.uuidString)#00:11:00|00:11:00]]
            """

            let document = LegacyMarkdownSummaryParser.parse(markdown: markdown, title: "List refs")

            #expect(document.sections.first?.blocks == [
                .bulletedList(items: [
                    SummaryText("Decide", transcriptRef: TranscriptReference(time: "00:10:00")),
                    SummaryText("Follow up", transcriptRef: TranscriptReference(time: "00:11:00")),
                ]),
            ])
        }
    }
#endif
