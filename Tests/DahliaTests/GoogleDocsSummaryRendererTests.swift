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
        func rendersNestedListIndentAndPerLevelNumbering() throws {
            let numberedItems = zip(["A", "B", "C", "D", "E"], [0, 1, 1, 0, 1]).map { text, indent in
                SummaryListItem(text: text, indent: indent)
            }
            let document = SummaryDocument(
                title: "Hierarchy",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "",
                        blocks: [
                            .bulletedList(items: [
                                SummaryListItem(text: "Root"),
                                SummaryListItem(text: "Child", indent: 1),
                                SummaryListItem(text: "Grandchild", indent: 2),
                            ]),
                            .numberedList(items: numberedItems),
                            .checklist(items: [
                                .init(text: "Task", checked: false),
                                .init(text: "Subtask", checked: true, indent: 1),
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

            #expect(rtf.contains(#"\li720\fi-360\tx720"#))
            #expect(rtf.contains(#"\li1440\fi-360\tx1440"#))
            #expect(rtf.contains(#"\li2160\fi-360\tx2160"#))
            #expect(rtf.contains("1.\\tab {A}"))
            #expect(rtf.contains("1.\\tab {B}"))
            #expect(rtf.contains("2.\\tab {C}"))
            #expect(rtf.contains("2.\\tab {D}"))
            #expect(rtf.contains("1.\\tab {E}"))
        }

        @Test
        func preservesEmptyTableCells() throws {
            let document = SummaryDocument(
                title: "Table",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "",
                        blocks: [
                            .table(
                                headers: ["First", "Second", "Third"],
                                rows: [["A", "", "C"]]
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

            #expect(rtf.contains(#"{A}\tab \tab {C}"#))

            let attributed = try NSAttributedString(
                data: rendered.data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            #expect(attributed.string.contains("A\t\tC"))
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
