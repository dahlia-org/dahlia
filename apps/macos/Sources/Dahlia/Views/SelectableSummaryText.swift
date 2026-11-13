import AppKit
import SwiftUI

struct SelectableSummaryText: View {
    let text: String
    let id: String
    let selection: TextSelectionGroup
    var font: NSFont = .dahliaBody
    var color: NSColor = DahliaDesign.primaryTextNSColor
    var isCode = false

    static func attributedText(_ text: String, font: NSFont, color: NSColor, isCode: Bool = false) -> NSMutableAttributedString {
        let inline = isCode ? AttributedString(text) : ((try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text))
        let result = NSMutableAttributedString(attributedString: NSAttributedString(inline))
        result.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: result.length))
        result.enumerateAttribute(.inlinePresentationIntent, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let raw = value as? NSNumber else { return }
            let intent = InlinePresentationIntent(rawValue: raw.uintValue)
            var resolved = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) : font
            if intent.contains(.stronglyEmphasized) { resolved = NSFontManager.shared.convert(resolved, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { resolved = NSFontManager.shared.convert(resolved, toHaveTrait: .italicFontMask) }
            result.addAttribute(.font, value: resolved, range: range)
            if intent.contains(.strikethrough) {
                result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        return result
    }

    var body: some View {
        SelectableText(id: id, text: displayedText, selection: selection)
    }

    private var displayedText: NSAttributedString {
        let attributed = Self.attributedText(text, font: font, color: color, isCode: isCode)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = DahliaDesign.paragraphLineSpacing
        attributed.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: attributed.length))
        return attributed
    }

}
