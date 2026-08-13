import AppKit
import DahliaRuntimeSupport

extension SummaryAttributedDocument {
    static func appendTextBlock(
        _ summaryText: SummaryText,
        font: NSFont = NSFont.preferredFont(forTextStyle: .body),
        color: NSColor = .labelColor,
        paragraphSpacing: CGFloat = DahliaDesign.blockSpacing,
        paragraphSpacingBefore: CGFloat = 0,
        to document: NSMutableAttributedString,
        transcriptTextProvider: (TranscriptReference) -> String?,
        allowsTranscriptReferencePopovers: Bool
    ) {
        beginBlock(in: document)
        let location = document.length
        appendInlineMarkdown(summaryText.text, to: document)
        appendTranscriptReference(
            summaryText.transcriptRef,
            to: document,
            transcriptTextProvider: transcriptTextProvider,
            allowsPopover: allowsTranscriptReferencePopovers
        )
        let range = NSRange(location: location, length: document.length - location)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = DahliaDesign.paragraphLineSpacing
        style.paragraphSpacing = paragraphSpacing
        style.paragraphSpacingBefore = paragraphSpacingBefore
        document.addAttributes([
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ], range: range)
    }

    static func appendList(
        _ items: [SummaryText],
        marker: (Int) -> String,
        markerFont: NSFont? = nil,
        markerColor: NSColor? = nil,
        to document: NSMutableAttributedString,
        transcriptTextProvider: (TranscriptReference) -> String?,
        allowsTranscriptReferencePopovers: Bool
    ) {
        for (index, item) in items.enumerated() {
            beginBlock(in: document)
            let location = document.length
            let marker = marker(index)
            document.append(NSAttributedString(string: "\(marker)\t"))
            appendInlineMarkdown(item.text, to: document)
            appendTranscriptReference(
                item.transcriptRef,
                to: document,
                transcriptTextProvider: transcriptTextProvider,
                allowsPopover: allowsTranscriptReferencePopovers
            )
            applyListStyle(
                to: document,
                range: NSRange(location: location, length: document.length - location)
            )
            var markerAttributes: [NSAttributedString.Key: Any] = [:]
            markerAttributes[.font] = markerFont
            markerAttributes[.foregroundColor] = markerColor
            document.addAttributes(
                markerAttributes.compactMapValues { $0 },
                range: NSRange(location: location, length: (marker as NSString).length)
            )
        }
    }

    static func appendChecklist(
        _ items: [SummaryBlock.ChecklistItem],
        to document: NSMutableAttributedString,
        transcriptTextProvider: (TranscriptReference) -> String?,
        allowsTranscriptReferencePopovers: Bool
    ) {
        for item in items {
            beginBlock(in: document)
            let location = document.length
            appendChecklistMarker(checked: item.checked, to: document)
            appendInlineMarkdown(item.text.text, to: document)
            appendTranscriptReference(
                item.text.transcriptRef,
                to: document,
                transcriptTextProvider: transcriptTextProvider,
                allowsPopover: allowsTranscriptReferencePopovers
            )
            applyListStyle(
                to: document,
                range: NSRange(location: location, length: document.length - location)
            )
        }
    }

    static func appendChecklistMarker(
        checked: Bool,
        to document: NSMutableAttributedString
    ) {
        let attachment = NSTextAttachment()
        let imageName = checked ? "checkmark.square" : "square"
        let color = checked ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
        let configuration = NSImage.SymbolConfiguration(hierarchicalColor: color)
        let accessibilityDescription = checked ? L10n.completed : L10n.waiting
        attachment.image = NSImage(systemSymbolName: imageName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(configuration)
        let marker = NSMutableAttributedString(attachment: attachment)
        marker.addAttribute(
            SummarySelectableNSTextView.copyReplacementAttribute,
            value: checked ? "- [x] " : "- [ ] ",
            range: NSRange(location: 0, length: marker.length)
        )
        marker.append(NSAttributedString(
            string: "\t",
            attributes: [SummarySelectableNSTextView.copyReplacementAttribute: ""]
        ))
        document.append(marker)
    }

    static func applyListStyle(
        to document: NSMutableAttributedString,
        range: NSRange
    ) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = DahliaDesign.paragraphLineSpacing
        style.paragraphSpacing = DahliaDesign.listItemSpacing
        style.firstLineHeadIndent = 8
        style.headIndent = 30
        style.tabStops = [NSTextTab(textAlignment: .left, location: 30)]
        document.addAttributes([
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ], range: range)
    }

    static func appendQuote(
        _ text: SummaryText,
        to document: NSMutableAttributedString,
        transcriptTextProvider: (TranscriptReference) -> String?,
        allowsTranscriptReferencePopovers: Bool
    ) {
        beginBlock(in: document)
        let location = document.length
        appendInlineMarkdown(text.text, to: document)
        appendTranscriptReference(
            text.transcriptRef,
            to: document,
            transcriptTextProvider: transcriptTextProvider,
            allowsPopover: allowsTranscriptReferencePopovers
        )
        let range = NSRange(location: location, length: document.length - location)
        let block = NSTextBlock()
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(.tertiaryLabelColor, for: .minX)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)

        let style = NSMutableParagraphStyle()
        style.lineSpacing = DahliaDesign.paragraphLineSpacing
        style.paragraphSpacing = DahliaDesign.blockSpacing
        style.textBlocks = [block]
        document.addAttributes([
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ], range: range)
    }

    static func appendCode(
        _ content: SummaryText,
        to document: NSMutableAttributedString,
        transcriptTextProvider: (TranscriptReference) -> String?,
        allowsTranscriptReferencePopovers: Bool
    ) {
        beginBlock(in: document)
        let location = document.length
        document.append(NSAttributedString(string: content.text))
        let range = NSRange(location: location, length: document.length - location)
        let block = NSTextBlock()
        block.backgroundColor = .quaternaryLabelColor
        block.setWidth(8, type: .absoluteValueType, for: .padding)

        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        style.textBlocks = [block]
        document.addAttributes([
            .font: NSFont.monospacedSystemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
                weight: .regular
            ),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ], range: range)

        guard content.transcriptRef != nil else { return }
        appendTextBlock(
            SummaryText("", transcriptRef: content.transcriptRef),
            paragraphSpacing: DahliaDesign.blockSpacing,
            to: document,
            transcriptTextProvider: transcriptTextProvider,
            allowsTranscriptReferencePopovers: allowsTranscriptReferencePopovers
        )
    }
}
