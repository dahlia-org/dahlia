import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct ObsidianMarkdownSummaryRendererTests {
        @Test
        func rendersFrontmatterFilenameTranscriptLinksAndImages() throws {
            let meetingId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E6"))
            let screenshotId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E7"))
            let createdAt = Date(timeIntervalSince1970: 1_783_598_400)
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
                            .paragraph(
                                SummaryText("Decision", transcriptRef: TranscriptReference(time: "00:10:00"))
                            ),
                            .image(
                                screenshotId: screenshotId,
                                caption: SummaryText("Screen", transcriptRef: TranscriptReference(time: "00:11:00"))
                            ),
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
            #expect(rendered.body.contains("![[\(screenshotId.uuidString).jpeg]]\n\nScreen"))
            #expect(rendered.body.contains("[[\(meetingId.uuidString)#00:11:00|00:11:00]]"))
            #expect(!rendered.body.contains("SQL(elements:"))
        }

        @Test
        func rendersCodeAndTableReferencesWithoutBreakingBlockMarkdown() throws {
            let meetingId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E6"))
            let createdAt = Date(timeIntervalSince1970: 1_783_598_400)
            let document = SummaryDocument(
                title: "Refs",
                sections: [
                    SummarySection(
                        id: UUID.v7(),
                        heading: "Summary",
                        blocks: [
                            .code(
                                language: "swift",
                                content: SummaryText("func f() {\n    return 1\n}", transcriptRef: TranscriptReference(time: "00:10:00"))
                            ),
                            .table(
                                headers: [SummaryText("Topic")],
                                rows: [[SummaryText("Launch", transcriptRef: TranscriptReference(time: "00:11:00"))]]
                            ),
                        ]
                    ),
                ]
            )
            let context = SummaryRenderContext(meetingId: meetingId, createdAt: createdAt)

            let rendered = ObsidianMarkdownSummaryRenderer.render(document: document, context: context)

            #expect(rendered.body.contains("```swift\nfunc f() {\n    return 1\n}\n```\n\n([[\(meetingId.uuidString)#00:10:00|00:10:00]])"))
            #expect(!rendered.body.contains("``` ([["))
            #expect(rendered.body.contains("| Launch ([[\(meetingId.uuidString)#00:11:00|00:11:00]]) |"))
        }

        @Test
        func rendersListItemReferencesOnEachItem() throws {
            let meetingId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E6"))
            let createdAt = Date(timeIntervalSince1970: 1_783_598_400)
            let document = SummaryDocument(
                title: "List refs",
                sections: [
                    SummarySection(
                        id: UUID.v7(),
                        heading: "Summary",
                        blocks: [
                            .bulletedList(items: [
                                SummaryText("Decision", transcriptRef: TranscriptReference(time: "00:10:00")),
                                SummaryText("Follow up", transcriptRef: TranscriptReference(time: "00:11:00")),
                            ]),
                        ]
                    ),
                ]
            )
            let context = SummaryRenderContext(meetingId: meetingId, createdAt: createdAt)

            let rendered = ObsidianMarkdownSummaryRenderer.render(document: document, context: context)

            #expect(rendered.body.contains("- Decision ([[\(meetingId.uuidString)#00:10:00|00:10:00]])"))
            #expect(rendered.body.contains("- Follow up ([[\(meetingId.uuidString)#00:11:00|00:11:00]])"))
        }

        @Test
        func legacyMarkdownParseRenderNormalizesScreenshotFilename() throws {
            let meetingId = UUID.v7()
            let screenshotId = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E6"))
            let createdAt = Date(timeIntervalSince1970: 1_783_598_400)
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
            #expect(rendered.body.contains("Screen"))
            #expect(!rendered.body.contains(".webp"))
        }
    }
#endif
