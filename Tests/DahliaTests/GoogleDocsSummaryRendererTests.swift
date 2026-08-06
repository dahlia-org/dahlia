import AppKit
import Foundation
@testable import Dahlia
@testable import DahliaRuntimeSupport

#if canImport(Testing)
    import Testing

    struct GoogleDocsSummaryRendererTests {
        @Test
        func rendersFormattedTextAndEmbeddedScreenshotAsRTF() throws {
            let screenshotID = UUID.v7()
            let screenshot = try MeetingScreenshotRecord(
                id: screenshotID,
                meetingId: .v7(),
                capturedAt: .now,
                imageData: makePNGData(),
                mimeType: "image/png"
            )
            let document = SummaryDocument(
                title: "週次ミーティング",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "Summary",
                        blocks: [
                            .paragraph("Ship **alpha**. See [docs](https://example.com)."),
                            .image(screenshotId: screenshotID, caption: "Launch screen"),
                        ]
                    ),
                ],
                actionItems: [
                    SummaryActionItem(title: "Send notes", assignee: "Aki"),
                ]
            )
            let context = SummaryRenderContext(
                meetingId: screenshot.meetingId,
                createdAt: .now,
                screenshots: [screenshot]
            )

            let rendered = GoogleDocsSummaryRenderer.render(
                document: document,
                context: context,
                actionItemsHeading: "Action Items",
                imageUnavailableText: "Image unavailable"
            )

            #expect(rendered.mimeType == "application/rtf")
            let rtf = try #require(String(data: rendered.data, encoding: .utf8))
            #expect(rtf.contains("\\pict\\jpegblip"))
            #expect(rtf.contains("ffd8"))
            #expect(rtf.contains("HYPERLINK \"https://example.com\""))

            let attributed = try NSAttributedString(
                data: rendered.data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            #expect(attributed.string.contains("週次ミーティング"))
            #expect(attributed.string.contains("Ship alpha. See docs."))
            #expect(attributed.string.contains("Launch screen"))
            #expect(attributed.string.contains("Send notes (Aki)"))
        }

        @Test
        func rendersFallbackWhenReferencedScreenshotIsUnavailable() throws {
            let document = SummaryDocument(
                title: "Summary",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "",
                        blocks: [.image(screenshotId: .v7(), caption: "Missing")]
                    ),
                ]
            )
            let context = SummaryRenderContext(meetingId: .v7(), createdAt: .now)

            let rendered = GoogleDocsSummaryRenderer.render(
                document: document,
                context: context,
                actionItemsHeading: "Action Items",
                imageUnavailableText: "Image unavailable"
            )
            let attributed = try NSAttributedString(
                data: rendered.data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )

            #expect(attributed.string.contains("Image unavailable: Missing"))
        }

        @Test
        func escapesRTFGroupDelimitersInSummaryText() throws {
            let code = #"{"path": "C:\Temp"}"#
            let document = SummaryDocument(
                title: "Summary",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "",
                        blocks: [.code(language: "json", code: code)]
                    ),
                ]
            )

            let rendered = GoogleDocsSummaryRenderer.render(
                document: document,
                context: SummaryRenderContext(meetingId: .v7(), createdAt: .now),
                actionItemsHeading: "Action Items",
                imageUnavailableText: "Image unavailable"
            )
            let rtf = try #require(String(data: rendered.data, encoding: .utf8))
            #expect(rtf.contains(#"\{"path": "C:\\Temp"\}"#))

            let attributed = try NSAttributedString(
                data: rendered.data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            #expect(attributed.string.contains(code))
        }

        @Test
        func rendersNestedListsWithRTFIndentAndDerivedNumbers() throws {
            let document = SummaryDocument(
                title: "Nested",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "",
                        blocks: [
                            .bulletedList(items: [
                                SummaryListItem(text: "Bullet parent"),
                                SummaryListItem(text: "Bullet child", indent: 1),
                                SummaryListItem(text: "Bullet grandchild", indent: 2),
                            ]),
                            .numberedList(items: [
                                SummaryListItem(text: "First"),
                                SummaryListItem(text: "First child", indent: 1),
                                SummaryListItem(text: "Second child", indent: 1),
                                SummaryListItem(text: "Grandchild", indent: 2),
                                SummaryListItem(text: "Second"),
                                SummaryListItem(text: "Reset child", indent: 1),
                            ]),
                            .checklist(items: [
                                .init(text: "Checklist parent", checked: false),
                                .init(text: "Checklist child", checked: true, indent: 1),
                                .init(text: "Checklist grandchild", checked: false, indent: 2),
                            ]),
                        ]
                    ),
                ]
            )

            let rendered = GoogleDocsSummaryRenderer.render(
                document: document,
                context: SummaryRenderContext(meetingId: .v7(), createdAt: .now),
                actionItemsHeading: "Action Items",
                imageUnavailableText: "Image unavailable"
            )
            let rtf = try #require(String(data: rendered.data, encoding: .utf8))

            #expect(rtf.contains("\\li720\\fi-360\\tx720"))
            #expect(rtf.contains("\\li1440\\fi-360\\tx1440"))
            #expect(rtf.contains("\\li2160\\fi-360\\tx2160"))
            #expect(rtf.contains("1.\\tab {First}"))
            #expect(rtf.contains("2.\\tab {Second child}"))
            #expect(rtf.contains("2.\\tab {Second}"))
            #expect(rtf.contains("1.\\tab {Reset child}"))
            #expect(rtf.contains("\\li1440\\fi-360\\tx1440\\sa80\\fs22 \\u8226 \\tab {Bullet child}"))
            #expect(rtf.contains("\\li2160\\fi-360\\tx2160\\sa80\\fs22 \\u8226 \\tab {Bullet grandchild}"))
            #expect(rtf.contains("\\li1440\\fi-360\\tx1440\\sa80\\fs22 \\u9745 \\tab {Checklist child}"))
            #expect(rtf.contains("\\li2160\\fi-360\\tx2160\\sa80\\fs22 \\u9744 \\tab {Checklist grandchild}"))
        }

        @Test
        func preservesEmptyTableCellsInRTF() throws {
            let document = SummaryDocument(
                title: "Table",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "",
                        blocks: [
                            .table(
                                headers: ["Header A", "", "Header C"],
                                rows: [["Cell A", "", "Cell C"]]
                            ),
                        ]
                    ),
                ]
            )

            let rendered = GoogleDocsSummaryRenderer.render(
                document: document,
                context: SummaryRenderContext(meetingId: .v7(), createdAt: .now),
                actionItemsHeading: "Action Items",
                imageUnavailableText: "Image unavailable"
            )
            let rtf = try #require(String(data: rendered.data, encoding: .utf8))

            #expect(rtf.contains("{Header A}\\tab \\tab {Header C}"))
            #expect(rtf.contains("{Cell A}\\tab \\tab {Cell C}"))
        }

        @Test
        func preservesLegacyBlankListItemsInRTF() throws {
            let document = SummaryDocument(
                schemaVersion: 3,
                title: "Legacy lists",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "",
                        blocks: [
                            .bulletedList(items: [SummaryListItem(text: "")]),
                            .numberedList(items: [
                                SummaryListItem(text: "First"),
                                SummaryListItem(text: ""),
                                SummaryListItem(text: "Third"),
                            ]),
                            .checklist(items: [.init(text: "", checked: false)]),
                        ]
                    ),
                ]
            )

            let rendered = GoogleDocsSummaryRenderer.render(
                document: document,
                context: SummaryRenderContext(meetingId: .v7(), createdAt: .now),
                actionItemsHeading: "Action Items",
                imageUnavailableText: "Image unavailable"
            )
            let rtf = try #require(String(data: rendered.data, encoding: .utf8))

            #expect(rtf.contains("\\u8226 \\tab \\par"))
            #expect(rtf.contains("2.\\tab \\par"))
            #expect(rtf.contains("3.\\tab {Third}"))
            #expect(rtf.contains("\\u9744 \\tab \\par"))
        }

        private func makePNGData() throws -> Data {
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2,
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
            pixels[4] = 0
            pixels[5] = 0
            pixels[6] = 255
            pixels[7] = 255
            return try #require(bitmap.representation(using: .png, properties: [:]))
        }
    }
#endif
