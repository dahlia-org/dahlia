import AppKit
import SwiftUI

struct TranscriptRowTextView: View {
    let segment: TranscriptSegment
    let showsTranslatedText: Bool
    let selection: TextSelectionGroup
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        SelectableText(id: segment.id.uuidString, text: attributedText, selection: selection)
    }

    private var attributedText: NSAttributedString {
        _ = dynamicTypeSize
        let text = TextSelectionGroup.text(for: segment, showsTranslatedText: showsTranslatedText)
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.dahliaBody,
            .foregroundColor: segment.isConfirmed ? DahliaDesign.primaryTextNSColor : DahliaDesign.secondaryTextNSColor,
        ])
        if let translation = segment.visibleTranslatedText(isEnabled: showsTranslatedText) {
            attributed.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: NSRange(
                location: attributed.length - translation.utf16.count,
                length: translation.utf16.count
            ))
        }
        return attributed
    }
}
