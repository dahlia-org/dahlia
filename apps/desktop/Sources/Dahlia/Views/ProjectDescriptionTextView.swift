import AppKit
import SwiftUI

struct ProjectDescriptionTextView: NSViewRepresentable {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textContainer = NSTextContainer(
            containerSize: NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = ProjectDescriptionNSTextView(
            frame: NSRect(origin: .zero, size: scrollView.contentSize),
            textContainer: textContainer
        )
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = DahliaDesign.primaryTextNSColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 10)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ProjectDescriptionNSTextView else { return }
        _ = dynamicTypeSize
        textView.isEditable = isEnabled
        textView.font = .preferredFont(forTextStyle: .body)
        guard textView.string != text,
              !textView.hasMarkedText()
        else { return }

        let selection = textView.selectedRange()
        textView.string = text
        let location = min(selection.location, text.utf16.count)
        textView.setSelectedRange(NSRange(
            location: location,
            length: min(selection.length, text.utf16.count - location)
        ))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ProjectDescriptionTextView

        init(parent: ProjectDescriptionTextView) {
            self.parent = parent
        }

        func textDidBeginEditing(_: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_: Notification) {
            parent.isFocused = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

final class ProjectDescriptionNSTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        insertNewlineIgnoringFieldEditor(nil)
    }
}
