import AppKit
import SwiftUI

struct SelectableTextContent: NSViewRepresentable {
    let id: String
    let text: NSAttributedString
    let selection: TextSelectionGroup

    func makeNSView(context _: Context) -> SelectableTextView {
        SelectableTextView.makeConfigured()
    }

    func updateNSView(_ view: SelectableTextView, context _: Context) {
        if view.attributedString() != text { view.textStorage?.setAttributedString(text) }
        view.selectionID = id
        view.selection = selection
        selection.register(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectableTextView, context _: Context) -> CGSize? {
        guard let container = nsView.textContainer, let manager = nsView.layoutManager else { return nil }
        let width = proposal.width ?? ceil(text.size().width)
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: max(nsView.font?.pointSize ?? NSFont.dahliaBody.pointSize, ceil(manager.usedRect(for: container).height)))
    }
}
