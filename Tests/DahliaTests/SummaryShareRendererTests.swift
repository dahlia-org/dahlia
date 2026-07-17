import AppKit
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct SummaryShareRendererTests {
        @Test
        func rendersGoogleDocsHTMLAndMarkdownWhileOmittingStructuredTranscriptReferences() {
            let document = SummaryDocument(
                title: "Weekly Sync",
                sections: [
                    SummarySection(
                        id: UUID.v7(),
                        heading: "Summary",
                        blocks: [
                            .paragraph(SummaryText(
                                "Ship **alpha** based on decision. See [docs](https://example.com?a=1&b=2).",
                                transcriptRef: TranscriptReference(time: "00:10:00")
                            )),
                            .bulletedList(items: [
                                SummaryText("Confirm rollout", transcriptRef: TranscriptReference(time: "00:11:00")),
                            ]),
                            .numberedList(items: [
                                SummaryText("Prepare notes"),
                            ]),
                            .checklist(items: [
                                SummaryBlock.ChecklistItem(text: SummaryText("Follow up"), checked: false),
                            ]),
                            .quote(SummaryText("Keep launch small")),
                            .code(language: "swift", content: SummaryText("let enabled = true")),
                        ]
                    ),
                ]
            )

            let content = SummaryShareRenderer.render(
                document: document,
                actionItemsHeading: "Action Items",
                for: .googleDocs
            )

            #expect(content.markdown.contains("# Weekly Sync"))
            #expect(content.markdown.contains("## Summary"))
            #expect(content.markdown.contains("Ship **alpha** based on decision."))
            #expect(content.markdown.contains("[docs](https://example.com?a=1&b=2)"))
            #expect(content.markdown.contains("- Confirm rollout"))
            #expect(content.markdown.contains("1. Prepare notes"))
            #expect(content.markdown.contains("- [ ] Follow up"))
            #expect(content.markdown.contains("> Keep launch small"))
            #expect(content.markdown.contains("```swift\nlet enabled = true\n```"))

            #expect(content.html.contains("<h1>Weekly Sync</h1>"))
            #expect(content.html.contains("<h2>Summary</h2>"))
            #expect(content.html.contains("Ship <strong>alpha</strong> based on decision."))
            #expect(content.html.contains("<a href=\"https://example.com?a=1&amp;b=2\">docs</a>"))
            #expect(content.html.contains("<ul>"))
            #expect(content.html.contains("<ol>"))
            #expect(content.html.contains("<li>Follow up</li>"))
            #expect(content.html.contains("<blockquote><p>Keep launch small</p></blockquote>"))
            #expect(content.html.contains("<pre><code>let enabled = true</code></pre>"))
            #expect(!content.html.contains("☑"))
            #expect(!content.html.contains("☐"))

            #expect(!content.markdown.contains("00:10:00"))
            #expect(!content.markdown.contains("00:11:00"))
            #expect(!content.html.contains("00:10:00"))
            #expect(!content.html.contains("00:11:00"))
        }

        @Test
        func embedsReferencedScreenshotAsJPEGOnlyInGoogleDocsHTML() throws {
            let screenshotID = UUID.v7()
            let screenshot = MeetingScreenshotRecord(
                id: screenshotID,
                meetingId: .v7(),
                capturedAt: .now,
                imageData: try makePNGData(),
                mimeType: "image/png"
            )
            let document = SummaryDocument(
                title: "Summary",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "",
                        blocks: [.image(screenshotId: screenshotID, caption: "Launch <screen>")]
                    ),
                ]
            )

            let googleDocsContent = SummaryShareRenderer.render(
                document: document,
                actionItemsHeading: "Action Items",
                for: .googleDocs,
                screenshots: [screenshot]
            )
            let slackContent = SummaryShareRenderer.render(
                document: document,
                actionItemsHeading: "Action Items",
                for: .slack,
                screenshots: [screenshot]
            )

            #expect(googleDocsContent.html.contains("<img src=\"data:image/jpeg;base64,"))
            #expect(googleDocsContent.html.contains("alt=\"Launch &lt;screen&gt;\""))
            #expect(googleDocsContent.html.contains("<figcaption><em>Launch &lt;screen&gt;</em></figcaption>"))
            #expect(googleDocsContent.markdown.contains("Launch <screen>"))
            #expect(!slackContent.html.contains("<img"))
            #expect(slackContent.html.contains("<em>Launch &lt;screen&gt;</em>"))
        }

        @Test
        func rendersSlackHeadingsAndExplicitLineBreaks() {
            let document = SummaryDocument(
                title: "Weekly Sync",
                sections: [
                    SummarySection(
                        id: UUID.v7(),
                        heading: "Summary",
                        blocks: [
                            .paragraph("Decision"),
                            .heading(level: 3, text: "Details"),
                            .paragraph("More"),
                            .heading(level: 4, text: "Notes"),
                            .bulletedList(items: ["One", "Two"]),
                            .numberedList(items: ["First", "Second"]),
                            .checklist(items: [
                                SummaryBlock.ChecklistItem(text: "Done", checked: true),
                                SummaryBlock.ChecklistItem(text: "Pending", checked: false),
                            ]),
                        ]
                    ),
                ],
                actionItems: [
                    SummaryActionItem(title: "Send notes", assignee: "Aki"),
                ]
            )

            let content = SummaryShareRenderer.render(
                document: document,
                actionItemsHeading: "Action Items",
                for: .slack
            )

            #expect(content.html.contains("<strong><em>Weekly Sync</em></strong><br><br>\n<strong><u>Summary</u></strong>"))
            #expect(content.html.contains("Decision<br><br>\n<strong>Details</strong><br><br>\nMore<br><br>\nNotes"))
            #expect(content.html.contains("Notes<br><br>\n<ul>\n<li>One</li>\n<li>Two</li>\n</ul>"))
            #expect(content.html.contains("<ol>\n<li>First</li>\n<li>Second</li>\n</ol>"))
            #expect(content.html.contains("<ul>\n<li>Done</li>\n<li>Pending</li>\n</ul>"))
            #expect(content.html.contains("<strong><u>Action Items</u></strong><br><br>\n<ul>\n<li>Send notes (Aki)</li>\n</ul>"))
            #expect(!content.html.contains("<h1>"))
            #expect(!content.html.contains("<h2>"))
            #expect(!content.html.contains("<h3>"))
            #expect(!content.html.contains("<strong>Notes</strong>"))
            #expect(!content.html.contains("• One"))
            #expect(!content.html.contains("☑"))
            #expect(!content.html.contains("☐"))
            #expect(content.markdown.contains("# Weekly Sync"))
            #expect(content.markdown.contains("## Summary"))
            #expect(content.markdown.contains("### Details"))
            #expect(content.markdown.contains("#### Notes"))
        }

        @Test
        func rendersStructuredActionItemsAndEscapesHTML() {
            let document = SummaryDocument(
                title: "Review <Draft>",
                sections: [],
                actionItems: [
                    SummaryActionItem(title: "Send **proposal**", assignee: "Aki & Ren"),
                    SummaryActionItem(title: "Schedule review", assignee: ""),
                ]
            )

            let content = SummaryShareRenderer.render(
                document: document,
                actionItemsHeading: "Action Items",
                for: .googleDocs
            )

            #expect(content.markdown == """
            # Review <Draft>

            ## Action Items
            - [ ] Send **proposal** (Aki & Ren)
            - [ ] Schedule review
            """)
            #expect(content.html.contains("<h1>Review &lt;Draft&gt;</h1>"))
            #expect(content.html.contains("<h2>Action Items</h2>"))
            #expect(content.html.contains("<li>Send <strong>proposal</strong> (Aki &amp; Ren)</li>"))
            #expect(content.html.contains("<li>Schedule review</li>"))
            #expect(!content.html.contains("☐"))
        }

        @MainActor
        @Test
        func writesHTMLAndPlainTextAsRepresentationsOfOnePasteboardItem() throws {
            let pasteboard = NSPasteboard(name: .init("SummaryShareRendererTests-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            let content = SummaryShareContent(html: "<strong>Summary</strong>", markdown: "**Summary**")

            #expect(SummaryPasteboardWriter.write(content, to: pasteboard))

            let items = try #require(pasteboard.pasteboardItems)
            let item = try #require(items.first)
            #expect(items.count == 1)
            #expect(item.string(forType: .html) == content.html)
            #expect(item.string(forType: .string) == content.markdown)
        }

        private func makePNGData() throws -> Data {
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1,
                pixelsHigh: 1,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
            let pixels = try #require(bitmap.bitmapData)
            pixels[0] = 255
            pixels[1] = 0
            pixels[2] = 0
            pixels[3] = 255
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
    }
#endif
