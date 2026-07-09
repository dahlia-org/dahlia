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
                .paragraph("Decide to ship ([00:10:00](transcript://00:10:00)) and see"),
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
    }
#endif
