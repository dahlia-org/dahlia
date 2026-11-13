import AppKit
import SwiftUI

struct SelectableText: View {
    let id: String
    let text: NSAttributedString
    let selection: TextSelectionGroup

    var body: some View {
        let font = text.length > 0 ? text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
        let baseline = (font ?? .dahliaBody).ascender
        SelectableTextContent(id: id, text: text, selection: selection)
            .alignmentGuide(.firstTextBaseline) { _ in baseline }
    }
}
