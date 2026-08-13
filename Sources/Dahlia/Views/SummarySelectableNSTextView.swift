import AppKit

@MainActor
final class SummarySelectableNSTextView: NSTextView {
    static let copyReplacementAttribute = NSAttributedString.Key(
        "com.kazukimasuda.Dahlia.summaryCopyReplacement"
    )

    static func makeConfigured() -> SummarySelectableNSTextView {
        let textView = SummarySelectableNSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        return textView
    }

    func setDocument(_ document: NSAttributedString) {
        let previousSelectedRanges = selectedRanges.map(\.rangeValue)
        textStorage?.setAttributedString(document)

        let documentLength = document.length
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
            selectedRanges = clippedRanges
        }
        invalidateIntrinsicContentSize()
    }

    func measuredHeight(constrainedTo width: CGFloat) -> CGFloat? {
        guard width > 0,
              let textContainer,
              let textLayoutManager,
              let documentRange = textLayoutManager.textContentManager?.documentRange
        else { return nil }

        frame.size.width = width
        textContainer.containerSize = CGSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textLayoutManager.ensureLayout(for: documentRange)
        return ceil(textLayoutManager.usageBoundsForTextContainer.height)
    }

    override func copy(_ sender: Any?) {
        let ranges = selectedRanges
            .map(\.rangeValue)
            .filter { $0.length > 0 }
        guard !ranges.isEmpty else {
            super.copy(sender)
            return
        }

        copySelectedText(to: .general, ranges: ranges)
    }

    func copySelectedText(to pasteboard: NSPasteboard, ranges: [NSRange]? = nil) {
        let ranges = ranges ?? selectedRanges.map(\.rangeValue)
        let copiedText = Self.plainText(from: attributedString(), ranges: ranges)
        pasteboard.clearContents()
        pasteboard.setString(copiedText, forType: .string)
    }

    static func plainText(
        from attributedString: NSAttributedString,
        ranges: [NSRange]
    ) -> String {
        ranges
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
            .map { plainText(from: attributedString, range: $0) }
            .joined(separator: "\n")
    }

    private static func plainText(
        from attributedString: NSAttributedString,
        range: NSRange
    ) -> String {
        var result = ""
        attributedString.enumerateAttributes(in: range) { attributes, effectiveRange, _ in
            if let replacement = attributes[copyReplacementAttribute] as? String {
                result += replacement
            } else if attributes[.attachment] == nil {
                result += attributedString.attributedSubstring(from: effectiveRange).string
            }
        }
        return result
    }
}
