#if canImport(Testing)
    import AppKit
    import CoreGraphics
    import Foundation
    import Testing
    import UniformTypeIdentifiers
    @testable import Dahlia
    @testable import DahliaRuntimeSupport

    @MainActor
    struct SummaryDocumentViewTests {
        @Test
        func selectionCopiesAcrossListImageAndSectionWhileOmittingReferences() {
            let screenshotID = UUID.v7()
            let reference = TranscriptReference(time: "00:01:23")
            let screenshot = MeetingScreenshotRecord(
                id: screenshotID,
                meetingId: .v7(),
                capturedAt: .now,
                imageData: Data([1, 2, 3]),
                mimeType: "image/png"
            )
            let document = SummaryDocument(
                title: "Title",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "Section One",
                        blocks: [
                            .bulletedList(items: [
                                SummaryText("First", transcriptRef: reference),
                                SummaryText("Second"),
                            ]),
                            .image(
                                screenshotId: screenshotID,
                                caption: SummaryText("Caption", transcriptRef: reference)
                            ),
                            .paragraph("After"),
                        ]
                    ),
                    SummarySection(
                        id: .v7(),
                        heading: "Section Two",
                        blocks: []
                    ),
                ]
            )
            let rendered = SummaryAttributedDocument.render(
                document,
                screenshotProvider: { $0 == screenshotID ? screenshot : nil },
                onOpenImage: { _, _ in },
                transcriptTextProvider: { _ in "Referenced transcript" },
                allowsTranscriptReferencePopovers: true
            )
            let source = rendered.string as NSString
            let start = source.range(of: "First").location
            let end = NSMaxRange(source.range(of: "Section Two"))

            let copied = SummarySelectableNSTextView.plainText(
                from: rendered,
                ranges: [NSRange(location: start, length: end - start)]
            )

            #expect(copied == "First\n•\tSecond\n\nCaption\nAfter\nSection Two")
            #expect(!copied.contains(reference.time))
            #expect(!copied.contains("\u{FFFC}"))
            #expect(attachmentCount(in: rendered) == 3)

            let textView = SummarySelectableNSTextView.makeConfigured()
            textView.setDocument(rendered)
            #expect(textView.measuredHeight(constrainedTo: 400).map { $0 > 120 } == true)
        }

        @Test
        func documentRendererPreservesBlockMeaningInPlainText() {
            let document = SummaryDocument(
                title: "**Meeting** notes",
                sections: [
                    SummarySection(
                        id: .v7(),
                        heading: "Details",
                        blocks: [
                            .numberedList(items: ["First", "Second"]),
                            .checklist(items: [
                                SummaryBlock.ChecklistItem(text: "Done", checked: true),
                                SummaryBlock.ChecklistItem(text: "Pending", checked: false),
                            ]),
                            .quote("Quoted"),
                            .code(language: "swift", code: "let value = 1"),
                            .heading(level: 3, text: "Subheading"),
                            .table(
                                headers: ["Name", "Value"],
                                rows: [["Alpha", "1"]]
                            ),
                        ]
                    ),
                ],
                actionItems: [
                    SummaryActionItem(title: "Follow up", assignee: "Kai"),
                ]
            )
            let rendered = SummaryAttributedDocument.render(
                document,
                screenshotProvider: { _ in nil },
                onOpenImage: { _, _ in },
                transcriptTextProvider: { _ in nil },
                allowsTranscriptReferencePopovers: false
            )

            let copied = SummarySelectableNSTextView.plainText(
                from: rendered,
                ranges: [NSRange(location: 0, length: rendered.length)]
            )

            #expect(copied.contains("Meeting notes\nDetails"))
            #expect(copied.contains("1.\tFirst\n2.\tSecond"))
            #expect(copied.contains("- [x] Done\n- [ ] Pending"))
            #expect(copied.contains("Quoted\nlet value = 1\nSubheading"))
            #expect(copied.contains("Name\tValue\nAlpha\t1"))
            #expect(copied.hasSuffix("\(L10n.actionItems)\n- [ ] Follow up (Kai)"))
        }

        @Test
        func attachmentCallbackUsesLatestOpenHandler() throws {
            let image = try #require(makeImage())
            var openedBy = ""
            let coordinator = SummarySelectableTextView.Coordinator { _, _ in
                openedBy = "first"
            }
            coordinator.openImage(.v7(), image)
            #expect(openedBy == "first")

            coordinator.onOpenImage = { _, _ in
                openedBy = "second"
            }
            coordinator.openImage(.v7(), image)

            #expect(openedBy == "second")
        }

        @Test
        func renderIdentityTracksDynamicTypeAndReferencedInputs() {
            let document = SummaryDocument(title: "Title", sections: [])
            let identity = SummarySelectableTextView.RenderIdentity(
                document: document,
                screenshotRevisions: [1],
                transcriptTexts: ["Transcript"],
                dynamicTypeSize: .large,
                allowsTranscriptReferencePopovers: true
            )

            #expect(identity != SummarySelectableTextView.RenderIdentity(
                document: document,
                screenshotRevisions: [1],
                transcriptTexts: ["Transcript"],
                dynamicTypeSize: .xLarge,
                allowsTranscriptReferencePopovers: true
            ))
            #expect(identity != SummarySelectableTextView.RenderIdentity(
                document: document,
                screenshotRevisions: [2],
                transcriptTexts: ["Updated"],
                dynamicTypeSize: .large,
                allowsTranscriptReferencePopovers: true
            ))
        }

        @Test
        func screenshotAttachmentUpdatesHeightAfterAsyncImageLoad() throws {
            let screenshot = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: .v7(),
                capturedAt: .now,
                imageData: Data([1, 2, 3]),
                mimeType: "image/png"
            )
            let attachment = SummaryAttributedDocument.screenshotAttachment(
                screenshot,
                caption: "",
                onOpenImage: { _, _ in }
            )
            #expect(attachment.size(for: 200).height == 120)

            try attachment.updateImageSize(#require(makeImage(width: 1, height: 2)))

            #expect(attachment.size(for: 200).height == 360)
        }

        @Test
        func selectableTextViewUsesTextKitTwoAndPreservesSelection() throws {
            let textView = SummarySelectableNSTextView.makeConfigured()
            #expect(textView.textLayoutManager != nil)
            textView.setDocument(NSAttributedString(string: "Alpha middle Omega"))
            textView.setSelectedRange(NSRange(location: 6, length: 6))

            textView.setDocument(NSAttributedString(string: "Alpha middle Omega extended"))

            #expect(textView.selectedRange() == NSRange(location: 6, length: 6))
            let wideHeight = try #require(textView.measuredHeight(constrainedTo: 400))
            let narrowHeight = try #require(textView.measuredHeight(constrainedTo: 80))
            #expect(wideHeight > 0)
            #expect(narrowHeight >= wideHeight)
        }

        @Test
        func copyWritesSelectedRangesInDocumentOrder() {
            let pasteboard = NSPasteboard(name: .init("SummaryDocumentViewTests-copy-\(UUID().uuidString)"))
            let textView = SummarySelectableNSTextView.makeConfigured()
            textView.setDocument(NSAttributedString(string: "Alpha middle Omega"))

            textView.copySelectedText(
                to: pasteboard,
                ranges: [
                    NSRange(location: 13, length: 5),
                    NSRange(location: 0, length: 5),
                ]
            )

            #expect(pasteboard.string(forType: .string) == "Alpha\nOmega")
        }

        @Test
        func screenshotActivationForwardsIdentifierAndPreviewOnce() throws {
            let screenshotID = UUID.v7()
            let image = try #require(makeImage())
            var openedScreenshotID: UUID?
            var openedImage: CGImage?
            var openCount = 0
            let screenshot = MeetingScreenshotRecord(
                id: screenshotID,
                meetingId: .v7(),
                capturedAt: .now,
                imageData: Data([1, 2, 3]),
                mimeType: "image/png"
            )
            let view = SummaryScreenshotImageView(
                screenshot: screenshot,
                accessibilityLabel: "Enlarge screenshot"
            ) { id, previewImage in
                openedScreenshotID = id
                openedImage = previewImage
                openCount += 1
            }

            view.activate(image)

            #expect(openedScreenshotID == screenshotID)
            #expect(openedImage === image)
            #expect(openCount == 1)
        }

        @Test
        func screenshotCopyWritesOriginalDataWithoutOpeningImage() async throws {
            let pasteboard = NSPasteboard(name: .init("SummaryDocumentViewTests-\(UUID().uuidString)"))
            let imageData = try #require(TestScreenshotImageFixture.data(using: .png))
            let screenshot = MeetingScreenshotRecord(
                id: .v7(),
                meetingId: .v7(),
                capturedAt: .now,
                imageData: imageData,
                mimeType: "image/png"
            )
            var openCount = 0
            let view = SummaryScreenshotImageView(
                screenshot: screenshot,
                accessibilityLabel: "Enlarge screenshot"
            ) { _, _ in
                openCount += 1
            }

            await view.copyImage(to: pasteboard)

            let type = NSPasteboard.PasteboardType(UTType.png.identifier)
            #expect(pasteboard.data(forType: type) == screenshot.imageData)
            #expect(openCount == 0)
        }

        private func makeImage(width: Int = 2, height: Int = 2) -> CGImage? {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            return context?.makeImage()
        }

        private func attachmentCount(in attributedString: NSAttributedString) -> Int {
            var count = 0
            attributedString.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: attributedString.length)
            ) { value, _, _ in
                count += value == nil ? 0 : 1
            }
            return count
        }
    }
#endif
