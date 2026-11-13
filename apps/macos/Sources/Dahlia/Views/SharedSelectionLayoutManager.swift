import AppKit

final class SharedSelectionLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>,
        count rectCount: Int,
        forCharacterRange charRange: NSRange,
        color: NSColor
    ) {
        let view = textContainers.first?.textView as? SelectableTextView
        // NSTextView calls this drawing adapter on the main thread.
        let emphasizesSelection = MainActor.assumeIsolated {
            guard let view, let selection = view.selection else { return false }
            return selection.isEmphasized(in: view.window) && NSIntersectionRange(charRange, view.selectedRange()).length > 0
        }
        guard emphasizesSelection, color == .unemphasizedSelectedContentBackgroundColor || color == .selectedTextBackgroundColor else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.selectedTextBackgroundColor.setFill()
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
    }
}
