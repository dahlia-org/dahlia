import AppKit
import DahliaRuntimeSupport

extension SummaryAttributedDocument {
    static func appendActionItems(
        _ actionItems: [SummaryActionItem],
        to document: NSMutableAttributedString
    ) {
        let displayableItems = actionItems.filter { $0.title.nilIfBlank != nil }
        guard !displayableItems.isEmpty else { return }

        appendTextBlock(
            SummaryText(L10n.actionItems),
            font: boldFont(for: .title3),
            paragraphSpacingBefore: DahliaDesign.sectionHeadingTopPadding,
            to: document,
            transcriptTextProvider: { _ in nil },
            allowsTranscriptReferencePopovers: false
        )

        for item in displayableItems {
            beginBlock(in: document)
            let location = document.length
            appendChecklistMarker(checked: false, to: document)
            appendInlineMarkdown(item.title, to: document)
            if let assignee = item.assignee.nilIfBlank {
                let assigneeLocation = document.length
                document.append(NSAttributedString(string: " (\(assignee))"))
                document.addAttribute(
                    .foregroundColor,
                    value: NSColor.secondaryLabelColor,
                    range: NSRange(
                        location: assigneeLocation,
                        length: document.length - assigneeLocation
                    )
                )
            }
            applyListStyle(
                to: document,
                range: NSRange(location: location, length: document.length - location)
            )
        }
    }

    static func appendInlineMarkdown(
        _ text: String,
        to document: NSMutableAttributedString
    ) {
        let attributed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        document.append(NSAttributedString(attributed))
    }

    static func beginBlock(in document: NSMutableAttributedString) {
        guard document.length > 0 else { return }
        document.append(NSAttributedString(string: "\n"))
    }

    static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1, 2:
            boldFont(for: .title3)
        case 3:
            boldFont(for: .headline)
        default:
            boldFont(for: .subheadline)
        }
    }

    static func boldFont(for textStyle: NSFont.TextStyle) -> NSFont {
        NSFontManager.shared.convert(
            NSFont.preferredFont(forTextStyle: textStyle),
            toHaveTrait: .boldFontMask
        )
    }

    static func applyInlinePresentationStyles(to document: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: document.length)
        document.enumerateAttribute(.inlinePresentationIntent, in: fullRange) { value, range, _ in
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
                document.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
        }
    }
}
