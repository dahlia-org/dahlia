#if canImport(Testing)
    import AppKit
    import Testing
    @testable import Dahlia

    @MainActor
    struct CodexChatMarkdownTextDocumentTests {
        @Test func groupsAdjacentTextBlocksAroundCodeBlocks() {
            let blocks: [CodexChatMarkdownRenderedBlock] = [
                .heading(level: 2, text: AttributedString("Heading")),
                .paragraph(AttributedString("Before")),
                .code(language: "swift", text: "let value = 1"),
                .blockquote(AttributedString("After")),
                .divider,
            ]

            #expect(CodexChatMarkdownRenderedGroup.build(from: blocks) == [
                .text(Array(blocks[0 ... 1])),
                .code(language: "swift", text: "let value = 1"),
                .text(Array(blocks[3 ... 4])),
            ])
        }

        @Test func buildsOneSelectableDocumentAcrossTextBlockTypes() throws {
            let link = try AttributedString(
                markdown: "**Bold** and [link](https://example.com)",
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
            let document = CodexChatMarkdownTextDocument.attributedString(for: [
                .heading(level: 2, text: AttributedString("Heading")),
                .paragraph(link),
                .unorderedList([
                    AttributedString("First"),
                    AttributedString("Second"),
                ]),
                .orderedList([
                    CodexChatMarkdownRenderedOrderedItem(
                        marker: "3.",
                        text: AttributedString("Third")
                    ),
                ]),
                .blockquote(AttributedString("Quoted")),
                .divider,
                .paragraph(AttributedString("Ending")),
            ])

            #expect(CodexChatMarkdownTextDocument.plainText(
                from: document,
                range: NSRange(location: 0, length: document.length)
            ) == [
                "Heading",
                "Bold and link",
                "•\tFirst",
                "•\tSecond",
                "3.\tThird",
                "Quoted",
                "",
                "Ending",
            ].joined(separator: "\n"))

            let source = document.string as NSString
            let selectionStart = source.range(of: "Heading").location
            let selectionEnd = NSMaxRange(source.range(of: "Second"))
            let selection = NSRange(location: selectionStart, length: selectionEnd - selectionStart)
            #expect(CodexChatMarkdownTextDocument.plainText(
                from: document,
                range: selection
            ) == [
                "Heading",
                "Bold and link",
                "•\tFirst",
                "•\tSecond",
            ].joined(separator: "\n"))

            let linkRange = source.range(of: "link")
            #expect(document.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))

            let boldRange = source.range(of: "Bold")
            let boldFont = document.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
            #expect(boldFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)

            let quoteRange = source.range(of: "Quoted")
            let quoteStyle = document.attribute(
                .paragraphStyle,
                at: quoteRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            #expect(quoteStyle?.textBlocks.count == 1)
        }

        @Test func rendersTableCellsAndCopiesRowsWithTabs() {
            let document = CodexChatMarkdownTextDocument.attributedString(for: [
                .table(CodexChatMarkdownRenderedTable(
                    header: [
                        AttributedString("Item"),
                        AttributedString("Value"),
                    ],
                    rows: [
                        [
                            AttributedString("Markdown"),
                            AttributedString("100"),
                        ],
                    ],
                    alignments: [.left, .right]
                )),
            ])

            #expect(CodexChatMarkdownTextDocument.plainText(
                from: document,
                range: NSRange(location: 0, length: document.length)
            ) == "Item\tValue\nMarkdown\t100")

            let source = document.string as NSString
            let tableCellRange = source.range(of: "Markdown")
            let tableCellStyle = document.attribute(
                .paragraphStyle,
                at: tableCellRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            #expect(tableCellStyle?.textBlocks.first is NSTextTableBlock)
        }

        @Test func preservesAndClipsSelectionWhenStreamingDocumentChanges() {
            let textView = CodexChatSelectableTextView()
            textView.setBlocks([.paragraph(AttributedString("Hello"))])
            textView.setSelectedRange(NSRange(location: 1, length: 4))

            textView.setBlocks([.paragraph(AttributedString("Hello world"))])
            #expect(textView.selectedRange() == NSRange(location: 1, length: 4))

            textView.setBlocks([.paragraph(AttributedString("Hel"))])
            #expect(textView.selectedRange() == NSRange(location: 1, length: 2))

            textView.setSelectedRange(NSRange(location: 3, length: 0))
            textView.setBlocks([.paragraph(AttributedString("H"))])
            #expect(textView.selectedRange() == NSRange(location: 1, length: 0))
        }

        @Test func reusesUnchangedDocumentPrefixDuringStreamingUpdates() {
            let textView = CodexChatSelectableTextView()
            textView.setBlocks([
                .paragraph(AttributedString("Stable prefix")),
                .paragraph(AttributedString("Old suffix")),
            ])
            let marker = NSAttributedString.Key("test.stable-prefix")
            textView.textStorage?.addAttribute(
                marker,
                value: true,
                range: NSRange(location: 0, length: 13)
            )

            textView.setBlocks([
                .paragraph(AttributedString("Stable prefix")),
                .paragraph(AttributedString("New suffix")),
            ])

            #expect(textView.string == "Stable prefix\nNew suffix")
            #expect(textView.attributedString().attribute(
                marker,
                at: 0,
                effectiveRange: nil
            ) as? Bool == true)
        }

        @Test func resizesFontsWithoutRebuildingTheDocument() {
            let textView = CodexChatSelectableTextView()
            let blocks: [CodexChatMarkdownRenderedBlock] = [.paragraph(AttributedString("Stable text"))]
            textView.setBlocks(blocks, baseFontSize: 14)
            let marker = NSAttributedString.Key("test.stable-font-resize")
            textView.textStorage?.addAttribute(marker, value: true, range: NSRange(location: 0, length: 6))

            textView.setBlocks(blocks, baseFontSize: 20)

            let font = textView.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            #expect(font?.pointSize == 20)
            #expect(textView.attributedString().attribute(marker, at: 0, effectiveRange: nil) as? Bool == true)
        }

        @Test func preservesLiteralZeroWidthSpacesWhenCopyingAcrossDivider() {
            let literalZeroWidthSpace = "\u{200B}"
            let document = CodexChatMarkdownTextDocument.attributedString(for: [
                .paragraph(AttributedString("Before\(literalZeroWidthSpace)after")),
                .divider,
                .paragraph(AttributedString("Ending")),
            ])

            #expect(CodexChatMarkdownTextDocument.plainText(
                from: document,
                range: NSRange(location: 0, length: document.length)
            ) == "Before\(literalZeroWidthSpace)after\n\nEnding")
        }

        @Test func serializesAllSelectedRangesInDocumentOrder() {
            let document = NSAttributedString(string: "Alpha middle Omega")

            #expect(CodexChatMarkdownTextDocument.plainText(
                from: document,
                ranges: [
                    NSRange(location: 13, length: 5),
                    NSRange(location: 0, length: 5),
                ]
            ) == "Alpha\nOmega")
        }

        @Test func boundsInitialLayoutForLargeDocument() {
            let textView = CodexChatSelectableTextView()
            let largeText = String(repeating: "Streaming Markdown line\n", count: 1000)
            textView.setBlocks([.paragraph(AttributedString(largeText))])

            let height = textView.measuredHeight(constrainedTo: 320)

            #expect(height != nil)
            let firstUnlaidGlyphIndex = textView.layoutManager?.firstUnlaidGlyphIndex() ?? 0
            let glyphCount = textView.layoutManager?.numberOfGlyphs ?? 0
            #expect(firstUnlaidGlyphIndex < glyphCount)
        }

        @Test func continuesBoundedLayoutFromReusableStreamingPrefix() {
            let textView = CodexChatSelectableTextView()
            let largeText = String(repeating: "Streaming Markdown line\n", count: 1000)
            textView.setBlocks([.paragraph(AttributedString(largeText))])
            _ = textView.measuredHeight(constrainedTo: 320)
            let firstLayoutEnd = textView.layoutManager?.firstUnlaidGlyphIndex() ?? 0

            textView.setBlocks([.paragraph(AttributedString("\(largeText)Appended"))])
            _ = textView.measuredHeight(constrainedTo: 320)
            let secondLayoutEnd = textView.layoutManager?.firstUnlaidGlyphIndex() ?? 0
            let glyphCount = textView.layoutManager?.numberOfGlyphs ?? 0

            #expect(secondLayoutEnd > firstLayoutEnd)
            #expect(secondLayoutEnd < glyphCount)
        }

        @Test func updatesMeasuredHeightWhenDocumentShrinksAtEnd() {
            let textView = CodexChatSelectableTextView()
            textView.setBlocks([
                .paragraph(AttributedString("First")),
                .paragraph(AttributedString(String(repeating: "Second\n", count: 20))),
            ])
            let expandedHeight = textView.measuredHeight(constrainedTo: 320) ?? 0

            textView.setBlocks([.paragraph(AttributedString("First"))])
            let collapsedHeight = textView.measuredHeight(constrainedTo: 320) ?? 0

            #expect(collapsedHeight < expandedHeight)
        }
    }
#endif
