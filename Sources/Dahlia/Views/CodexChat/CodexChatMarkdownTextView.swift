import AppKit
import SwiftUI

struct CodexChatMarkdownTextView: NSViewRepresentable {
    let blocks: [CodexChatMarkdownRenderedBlock]

    func makeNSView(context _: Context) -> CodexChatSelectableTextView {
        let textView = CodexChatSelectableTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        return textView
    }

    func updateNSView(_ textView: CodexChatSelectableTextView, context _: Context) {
        textView.setBlocks(blocks)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: CodexChatSelectableTextView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager
        else { return nil }

        textContainer.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let height = ceil(layoutManager.usedRect(for: textContainer).height)
        return CGSize(width: width, height: max(height, NSFont.preferredFont(forTextStyle: .body).pointSize))
    }
}

final class CodexChatSelectableTextView: NSTextView {
    private var renderedBlocks: [CodexChatMarkdownRenderedBlock] = []
    private var blockOffsets: [Int] = []

    func setBlocks(_ blocks: [CodexChatMarkdownRenderedBlock]) {
        let reusableBlockCount = zip(renderedBlocks, blocks)
            .prefix { $0 == $1 }
            .count
        guard reusableBlockCount < renderedBlocks.count || reusableBlockCount < blocks.count else {
            return
        }

        let previousSelectedRanges = selectedRanges.map(\.rangeValue)
        let previousDocumentLength = attributedString().length
        let replacementLocation = if reusableBlockCount < blockOffsets.count {
            blockOffsets[reusableBlockCount]
        } else {
            previousDocumentLength
        }
        let fragment = CodexChatMarkdownTextDocument.fragment(
            for: Array(blocks.dropFirst(reusableBlockCount)),
            startsAfterBlock: reusableBlockCount > 0
        )
        let replacementRange = NSRange(
            location: replacementLocation,
            length: previousDocumentLength - replacementLocation
        )
        textStorage?.replaceCharacters(in: replacementRange, with: fragment.attributedString)
        blockOffsets = Array(blockOffsets.prefix(reusableBlockCount))
            + fragment.blockOffsets.map { replacementLocation + $0 }
        renderedBlocks = blocks

        let documentLength = attributedString().length
        let clippedRanges = previousSelectedRanges.compactMap { range -> NSValue? in
            guard range.location <= documentLength else { return nil }
            return NSValue(range: NSRange(
                location: range.location,
                length: min(range.length, documentLength - range.location)
            ))
        }
        if clippedRanges.isEmpty {
            setSelectedRange(NSRange(location: documentLength, length: 0))
        } else {
            self.selectedRanges = clippedRanges
        }
        invalidateIntrinsicContentSize()
    }

    override func copy(_ sender: Any?) {
        let ranges = selectedRanges
            .map(\.rangeValue)
            .filter { $0.length > 0 }
        guard !ranges.isEmpty else {
            super.copy(sender)
            return
        }

        let copiedText = CodexChatMarkdownTextDocument.plainText(
            from: attributedString(),
            ranges: ranges
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copiedText, forType: .string)
    }
}

@MainActor
enum CodexChatMarkdownTextDocument {
    private static let dividerCharacter = "\u{200B}"
    private static let dividerAttribute = NSAttributedString.Key(
        "com.kazukimasuda.Dahlia.markdownDivider"
    )

    static func attributedString(
        for blocks: [CodexChatMarkdownRenderedBlock]
    ) -> NSAttributedString {
        fragment(for: blocks, startsAfterBlock: false).attributedString
    }

    static func fragment(
        for blocks: [CodexChatMarkdownRenderedBlock],
        startsAfterBlock: Bool
    ) -> Fragment {
        let document = NSMutableAttributedString()
        var blockOffsets: [Int] = []

        for (index, block) in blocks.enumerated() {
            blockOffsets.append(document.length)
            if startsAfterBlock || index > 0 {
                document.append(NSAttributedString(string: "\n"))
            }
            append(block, to: document)
        }

        applyInlinePresentationStyles(to: document)
        return Fragment(
            attributedString: document,
            blockOffsets: blockOffsets
        )
    }

    static func plainText(
        from attributedString: NSAttributedString,
        range: NSRange
    ) -> String {
        var result = ""
        attributedString.enumerateAttribute(
            dividerAttribute,
            in: range
        ) { value, effectiveRange, _ in
            guard value == nil else { return }
            result += attributedString.attributedSubstring(from: effectiveRange).string
        }
        return result
    }

    static func plainText(
        from attributedString: NSAttributedString,
        ranges: [NSRange]
    ) -> String {
        ranges
            .sorted { $0.location < $1.location }
            .map { plainText(from: attributedString, range: $0) }
            .joined(separator: "\n")
    }

    private static func append(
        _ block: CodexChatMarkdownRenderedBlock,
        to document: NSMutableAttributedString
    ) {
        switch block {
        case let .paragraph(text):
            appendParagraph(text, to: document)
        case let .heading(level, text):
            appendHeading(level: level, text: text, to: document)
        case let .unorderedList(items):
            appendUnorderedList(items, to: document)
        case let .orderedList(items):
            appendOrderedList(items, to: document)
        case let .blockquote(text):
            appendBlockquote(text, to: document)
        case .divider:
            appendDivider(to: document)
        case .code:
            break
        }
    }

    private static func appendParagraph(
        _ text: AttributedString,
        to document: NSMutableAttributedString
    ) {
        let range = append(text, to: document)
        applyBodyFont(to: document, range: range)
        applyParagraphStyle(to: document, range: range)
    }

    private static func appendHeading(
        level: Int,
        text: AttributedString,
        to document: NSMutableAttributedString
    ) {
        let range = append(text, to: document)
        let style: NSFont.TextStyle = switch level {
        case 1: .title1
        case 2: .title2
        case 3: .title3
        default: .headline
        }
        document.addAttribute(
            .font,
            value: NSFontManager.shared.convert(
                NSFont.preferredFont(forTextStyle: style),
                toHaveTrait: .boldFontMask
            ),
            range: range
        )
        applyParagraphStyle(to: document, range: range)
    }

    private static func appendUnorderedList(
        _ items: [AttributedString],
        to document: NSMutableAttributedString
    ) {
        for (index, item) in items.enumerated() {
            if index > 0 {
                document.append(NSAttributedString(string: "\n"))
            }
            appendListItem(marker: "•", text: item, to: document)
        }
    }

    private static func appendOrderedList(
        _ items: [CodexChatMarkdownRenderedOrderedItem],
        to document: NSMutableAttributedString
    ) {
        for (index, item) in items.enumerated() {
            if index > 0 {
                document.append(NSAttributedString(string: "\n"))
            }
            appendListItem(marker: item.marker, text: item.text, to: document)
        }
    }

    private static func appendListItem(
        marker: String,
        text: AttributedString,
        to document: NSMutableAttributedString
    ) {
        let location = document.length
        document.append(NSAttributedString(string: "\(marker)\t"))
        document.append(NSAttributedString(text))
        let range = NSRange(location: location, length: document.length - location)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = Self.paragraphSpacing
        style.firstLineHeadIndent = 0
        style.headIndent = 22
        style.tabStops = [NSTextTab(textAlignment: .left, location: 22)]
        document.addAttribute(.paragraphStyle, value: style, range: range)
        applyBodyFont(to: document, range: range)
    }

    private static func appendBlockquote(
        _ text: AttributedString,
        to document: NSMutableAttributedString
    ) {
        let range = append(text, to: document)
        let block = NSTextBlock()
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(.tertiaryLabelColor, for: .minX)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)

        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = Self.paragraphSpacing
        style.textBlocks = [block]
        document.addAttribute(.paragraphStyle, value: style, range: range)
        document.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        applyBodyFont(to: document, range: range)
    }

    private static func appendDivider(to document: NSMutableAttributedString) {
        let location = document.length
        document.append(NSAttributedString(string: dividerCharacter))

        let block = NSTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(.separatorColor, for: .maxY)
        block.setWidth(4, type: .absoluteValueType, for: .padding)

        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        document.addAttribute(
            .paragraphStyle,
            value: style,
            range: NSRange(location: location, length: 1)
        )
        document.addAttribute(
            dividerAttribute,
            value: true,
            range: NSRange(location: location, length: 1)
        )
    }

    @discardableResult
    private static func append(
        _ text: AttributedString,
        to document: NSMutableAttributedString
    ) -> NSRange {
        let location = document.length
        document.append(NSAttributedString(text))
        return NSRange(location: location, length: document.length - location)
    }

    private static func applyParagraphStyle(
        to document: NSMutableAttributedString,
        range: NSRange
    ) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = Self.paragraphSpacing
        document.addAttribute(
            .paragraphStyle,
            value: style,
            range: range
        )
    }

    private static func applyBodyFont(
        to document: NSMutableAttributedString,
        range: NSRange
    ) {
        document.addAttribute(
            .font,
            value: NSFont.preferredFont(forTextStyle: .body),
            range: range
        )
    }

    private static func applyInlinePresentationStyles(
        to document: NSMutableAttributedString
    ) {
        let fullRange = NSRange(location: 0, length: document.length)
        document.enumerateAttribute(
            .inlinePresentationIntent,
            in: fullRange
        ) { value, range, _ in
            guard let rawValue = value as? NSNumber else { return }
            let intent = InlinePresentationIntent(rawValue: rawValue.uintValue)
            let currentFont = document.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
                ?? NSFont.preferredFont(forTextStyle: .body)
            var font = currentFont

            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: currentFont.pointSize, weight: .regular)
            }
            if intent.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            document.addAttribute(.font, value: font, range: range)
            if intent.contains(.strikethrough) {
                document.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
    }

    private static let paragraphSpacing: CGFloat = 10

    struct Fragment {
        let attributedString: NSAttributedString
        let blockOffsets: [Int]
    }
}
