import AppKit

final class SelectableTextView: NSTextView {
    var selectionID = ""
    weak var selection: TextSelectionGroup?

    static func makeConfigured() -> SelectableTextView {
        let container = NSTextContainer()
        let manager = SharedSelectionLayoutManager()
        manager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(manager)
        let view = SelectableTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        return view
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let insertionIndex = characterIndexForInsertion(at: point)
        if insertionIndex < attributedString().length,
           attributedString().attribute(.link, at: insertionIndex, effectiveRange: nil) != nil {
            selection?.clear()
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        let granularity: NSSelectionGranularity = switch event.clickCount {
        case 2: .selectByWord
        case 3...: .selectByParagraph
        default: .selectByCharacter
        }
        let extending = event.modifierFlags.contains(.shift)
        let initialRange = extending ? selectedRange() : selectionRange(
            forProposedRange: NSRange(location: characterIndexForInsertion(at: point), length: 0),
            granularity: granularity
        )
        selection?.begin(at: .init(id: selectionID, offset: initialRange.location), extending: extending)
        if extending {
            selection?.extend(event: event, from: self, initialRange: initialRange, granularity: granularity, preservingAnchor: true)
        } else {
            setSelectedRange(initialRange)
        }
        var lastDrag: NSEvent?
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            if next.type == .leftMouseUp { break }
            if next.type == .leftMouseDragged { lastDrag = next }
            guard let lastDrag else { continue }
            autoscroll(with: lastDrag)
            selection?.extend(event: lastDrag, from: self, initialRange: initialRange, granularity: granularity, preservingAnchor: extending)
        }
        selection?.finish()
    }

    override func draw(_ dirtyRect: NSRect) {
        selection?.refreshEmphasis(in: window)
        super.draw(dirtyRect)
    }

    override func keyDown(with event: NSEvent) {
        if !(event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c") {
            selection?.clear(excluding: self)
        }
        super.keyDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if selectedRange().length == 0 { selection?.clear(excluding: self) }
        super.rightMouseDown(with: event)
    }

    override func copy(_ sender: Any?) {
        guard let text = selection?.selectedText else {
            super.copy(sender)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        if selection?.selectAll() != true { super.selectAll(sender) }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)), selection?.selectedText != nil { return true }
        return super.validateUserInterfaceItem(item)
    }
}
