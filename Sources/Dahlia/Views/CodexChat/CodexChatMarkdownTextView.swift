import AppKit
import SwiftUI

struct CodexChatMarkdownTextView: NSViewRepresentable {
    let blocks: [CodexChatMarkdownRenderedBlock]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeNSView(context _: Context) -> CodexChatSelectableTextView {
        CodexChatSelectableTextView.makeConfigured()
    }

    func updateNSView(_ textView: CodexChatSelectableTextView, context _: Context) {
        textView.setBlocks(blocks, dynamicTypeSize: dynamicTypeSize)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: CodexChatSelectableTextView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width,
              let measuredHeight = textView.measuredHeight(constrainedTo: width)
        else { return nil }

        return CGSize(
            width: width,
            height: max(measuredHeight, NSFont.preferredFont(forTextStyle: .body).pointSize)
        )
    }
}

final class CodexChatSelectableTextView: NSTextView {
    private static let layoutBatchCharacterCount = 4096
    /// リサイズドラッグのように幅が連続で変わる間、レイアウトのやり直しを 1 表示フレームぶん待って合流させる。
    private static let settleInterval = Duration.milliseconds(16)
    private static let batchInterval = Duration.milliseconds(1)

    private var renderedBlocks: [CodexChatMarkdownRenderedBlock] = []
    private var renderedDynamicTypeSize: DynamicTypeSize?
    private var blockOffsets: [Int] = []
    private var measuredDocumentHeight: CGFloat = 0
    private var measuredWidth: CGFloat?
    private var nextLayoutCharacterIndex = 0
    private var needsImmediateLayout = true
    private var layoutGeneration = 0
    private var layoutTask: Task<Void, Never>?

    static func makeConfigured() -> Self {
        let textView = Self()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textColor = DahliaDesign.primaryTextNSColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        return textView
    }

    func setBlocks(
        _ blocks: [CodexChatMarkdownRenderedBlock],
        dynamicTypeSize: DynamicTypeSize = .medium
    ) {
        let typographyChanged = renderedDynamicTypeSize != dynamicTypeSize
        if typographyChanged {
            renderedBlocks = []
            blockOffsets = []
            renderedDynamicTypeSize = dynamicTypeSize
        }
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
        let reusableCharacterCount = if typographyChanged {
            0
        } else {
            CodexChatMarkdownTextDocument.reusablePrefixLength(
                in: attributedString(),
                startingAt: replacementRange.location,
                and: fragment.attributedString
            )
        }
        let incrementalReplacementLocation = replacementLocation + reusableCharacterCount
        if typographyChanged {
            textStorage?.setAttributedString(fragment.attributedString)
        } else {
            textStorage?.replaceCharacters(
                in: NSRange(
                    location: incrementalReplacementLocation,
                    length: previousDocumentLength - incrementalReplacementLocation
                ),
                with: fragment.attributedString.attributedSubstring(from: NSRange(
                    location: reusableCharacterCount,
                    length: fragment.attributedString.length - reusableCharacterCount
                ))
            )
        }
        blockOffsets = Array(blockOffsets.prefix(reusableBlockCount))
            + fragment.blockOffsets.map { replacementLocation + $0 }
        renderedBlocks = blocks
        resetLayout(from: incrementalReplacementLocation)

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

    func measuredHeight(constrainedTo width: CGFloat) -> CGFloat? {
        guard let textContainer, layoutManager != nil else { return nil }

        if measuredWidth != width {
            let previousWidth = measuredWidth
            measuredWidth = width
            textContainer.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
            resetLayout(from: 0)
            // 実測済みの高さがあるなら、同期レイアウトをやり直さず面積を保つ近似値を返し、
            // 正確な高さは段階レイアウトの収束に任せる。
            if let previousWidth, measuredDocumentHeight > 0 {
                measuredDocumentHeight = ceil(measuredDocumentHeight * previousWidth / width)
                needsImmediateLayout = false
            }
        }
        if needsImmediateLayout {
            needsImmediateLayout = false
            layoutNextBatch()
        }
        scheduleRemainingLayout()
        return measuredDocumentHeight
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

    private func resetLayout(from characterIndex: Int) {
        layoutGeneration += 1
        layoutTask?.cancel()
        layoutTask = nil
        nextLayoutCharacterIndex = min(nextLayoutCharacterIndex, characterIndex)
        needsImmediateLayout = true
    }

    private func layoutNextBatch() {
        guard let layoutManager, let textContainer else { return }
        let documentLength = attributedString().length
        guard nextLayoutCharacterIndex < documentLength else {
            measuredDocumentHeight = documentLength == 0
                ? 0
                : ceil(layoutManager.usedRect(for: textContainer).height)
            return
        }

        let batchEnd = min(
            nextLayoutCharacterIndex + Self.layoutBatchCharacterCount,
            documentLength
        )
        layoutManager.ensureLayout(forCharacterRange: NSRange(
            location: nextLayoutCharacterIndex,
            length: batchEnd - nextLayoutCharacterIndex
        ))
        nextLayoutCharacterIndex = batchEnd

        if batchEnd == documentLength {
            measuredDocumentHeight = ceil(layoutManager.usedRect(for: textContainer).height)
        } else {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: 0, length: batchEnd),
                actualCharacterRange: nil
            )
            measuredDocumentHeight = ceil(
                layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer).maxY
            )
        }
    }

    private func scheduleRemainingLayout() {
        guard nextLayoutCharacterIndex < attributedString().length,
              layoutTask == nil
        else { return }

        let generation = layoutGeneration
        layoutTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var interval = Self.settleInterval
            while !Task.isCancelled, layoutGeneration == generation {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                guard !Task.isCancelled, layoutGeneration == generation else { break }
                interval = Self.batchInterval

                let previousHeight = measuredDocumentHeight
                layoutNextBatch()
                if measuredDocumentHeight != previousHeight {
                    invalidateIntrinsicContentSize()
                }
                if nextLayoutCharacterIndex >= attributedString().length {
                    break
                }
            }

            if layoutGeneration == generation {
                layoutTask = nil
            }
        }
    }
}

@MainActor
enum CodexChatMarkdownTextDocument {
    private static let dividerCharacter = "\u{200B}"
    private static let dividerAttribute = NSAttributedString.Key(
        "com.kazukimasuda.Dahlia.markdownDivider"
    )
    static let copyReplacementAttribute = NSAttributedString.Key(
        "com.kazukimasuda.Dahlia.markdownCopyReplacement"
    )

    static func attributedString(for blocks: [CodexChatMarkdownRenderedBlock]) -> NSAttributedString {
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
        attributedString.enumerateAttributes(
            in: range
        ) { attributes, effectiveRange, _ in
            if attributes[dividerAttribute] != nil {
                return
            }
            if let replacement = attributes[copyReplacementAttribute] as? String {
                result += replacement
            } else {
                result += attributedString.attributedSubstring(from: effectiveRange).string
            }
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
        case let .table(table):
            appendTable(table, to: document)
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
        let textStyle: NSFont.TextStyle = level == 1 ? .title3 : .headline
        document.addAttribute(
            .font,
            value: NSFont.preferredFont(forTextStyle: textStyle),
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
        document.addAttribute(.foregroundColor, value: DahliaDesign.secondaryTextNSColor, range: range)
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

    static func applyBodyFont(
        to document: NSMutableAttributedString,
        range: NSRange
    ) {
        document.addAttribute(
            .font,
            value: NSFont.preferredFont(forTextStyle: .body),
            range: range
        )
    }

    private static func applyInlinePresentationStyles(to document: NSMutableAttributedString) {
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
