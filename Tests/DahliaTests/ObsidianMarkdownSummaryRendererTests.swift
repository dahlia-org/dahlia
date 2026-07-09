import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct ObsidianMarkdownSummaryRendererTests {
        @Test
        func rendersFrontmatterFilenameTranscriptLinksAndImages() throws {
            let meetingId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E6"))
            let screenshotId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E7"))
            let createdAt = Date(timeIntervalSince1970: 1_783_536_000)
            let screenshot = MeetingScreenshotRecord(
                id: screenshotId,
                meetingId: meetingId,
                capturedAt: createdAt,
                imageData: Data(),
                mimeType: "image/jpeg"
            )
            let document = SummaryDocument(
                title: "Weekly Sync/Review",
                sections: [
                    SummarySection(
                        id: UUID.v7(),
                        heading: "Summary",
                        blocks: [
                            .paragraph("Decision [00:10:00](transcript://00:10:00)"),
                            .image(screenshotId: screenshotId, caption: "Screen"),
                        ]
                    ),
                ],
                tags: ["team"]
            )
            let context = SummaryRenderContext(meetingId: meetingId, createdAt: createdAt, screenshots: [screenshot])

            let rendered = ObsidianMarkdownSummaryRenderer.render(document: document, context: context)

            #expect(rendered.fileName == "2026-07-09-Weekly-SyncReview.md")
            #expect(rendered.markdown.contains("meeting_id: \"\(meetingId.uuidString)\""))
            #expect(rendered.markdown.contains("title: \"Weekly Sync/Review\""))
            #expect(rendered.markdown.contains("tags:\n  - team"))
            #expect(rendered.body.contains("[[\(meetingId.uuidString)#00:10:00|00:10:00]]"))
            #expect(rendered.body.contains("![[\(screenshotId.uuidString).jpeg]]"))
        }

        @Test
        func legacyMarkdownParseRenderNormalizesScreenshotFilename() throws {
            let meetingId = UUID.v7()
            let screenshotId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E6"))
            let createdAt = Date(timeIntervalSince1970: 1_783_536_000)
            let screenshot = MeetingScreenshotRecord(
                id: screenshotId,
                meetingId: meetingId,
                capturedAt: createdAt,
                imageData: Data(),
                mimeType: "image/jpeg"
            )
            let context = SummaryRenderContext(meetingId: meetingId, createdAt: createdAt, screenshots: [screenshot])
            let document = LegacyMarkdownSummaryParser.parse(
                markdown: "## Summary\n\nSee ![[_dahlia/screenshots/\(screenshotId.uuidString).webp|Screen]]",
                title: "Legacy",
                context: context
            )

            let rendered = ObsidianMarkdownSummaryRenderer.render(document: document, context: context)

            #expect(rendered.body.contains("![[\(screenshotId.uuidString).jpeg]]"))
            #expect(!rendered.body.contains(".webp"))
        }
    }
#endif
