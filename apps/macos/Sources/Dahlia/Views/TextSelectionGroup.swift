import AppKit

/// Shares selection and copying across independently laid out text views.
@MainActor
final class TextSelectionGroup {
    struct Position {
        let id: String
        let offset: Int
    }

    private let views = NSHashTable<SelectableTextView>.weakObjects()
    private var anchor: Position?
    private var extent: Position?
    private var rows: [(id: String, text: String)] = []
    private var indexes: [String: Int] = [:]
    private var displayedEmphasis = false

    func update(segments: [TranscriptSegment], showsTranslatedText: Bool) {
        update(rows: segments.map { ($0.id.uuidString, Self.text(for: $0, showsTranslatedText: showsTranslatedText)) })
    }

    func update(rows updated: [(id: String, text: String)]) {
        guard !rows.elementsEqual(updated, by: { $0.id == $1.0 && $0.text == $1.1 }) else { return }
        let protectedIDs = protectedRowIDs()
        let previous = rows.filter { protectedIDs.contains($0.id) }
        let surviving = updated.indices.filter { protectedIDs.contains(updated[$0].id) }
        let replacement = if let first = surviving.first, let last = surviving.last {
            Array(updated[first ... last])
        } else {
            [] as [(id: String, text: String)]
        }
        let preservesSelection = !previous.isEmpty && previous.elementsEqual(replacement, by: { $0.id == $1.id && $0.text == $1.text })
        if !preservesSelection { clear() }
        rows = updated
        indexes = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        if preservesSelection { finish() }
    }

    private func protectedRowIDs() -> Set<String> {
        if let anchor, let extent, let start = indexes[anchor.id], let end = indexes[extent.id] {
            return Set(rows[min(start, end) ... max(start, end)].map(\.id))
        }
        var ids = Set(views.allObjects.filter { $0.selectedRange().length > 0 }.map(\.selectionID))
        if let anchor { ids.insert(anchor.id) }
        return ids
    }

    func isEmphasized(in window: NSWindow?) -> Bool {
        window?.isKeyWindow == true && (window?.firstResponder as? SelectableTextView)?.selection === self
    }

    func refreshEmphasis(in window: NSWindow?) {
        let emphasized = isEmphasized(in: window)
        guard displayedEmphasis != emphasized else { return }
        displayedEmphasis = emphasized
        for view in views.allObjects {
            view.needsDisplay = true
        }
    }

    static func text(for segment: TranscriptSegment, showsTranslatedText: Bool) -> String {
        if let translation = segment.visibleTranslatedText(isEnabled: showsTranslatedText) {
            return segment.displayText + "\n" + translation
        }
        return segment.displayText
    }

    func register(_ view: SelectableTextView) {
        views.add(view)
        if extent != nil { apply(to: view) }
    }

    func begin(at position: Position, extending: Bool = false) {
        if extending, anchor != nil { return }
        clear()
        anchor = position
    }

    func extend(to position: Position) {
        extent = position
        for view in views.allObjects {
            apply(to: view)
        }
    }

    func extend(
        event: NSEvent,
        from origin: SelectableTextView,
        initialRange: NSRange,
        granularity: NSSelectionGranularity,
        preservingAnchor: Bool = false
    ) {
        let candidates = views.allObjects.filter { $0.window === origin.window && !$0.visibleRect.isEmpty }
        let target = candidates.min { lhs, rhs in
            distance(to: lhs, event: event) < distance(to: rhs, event: event)
        }
        guard let target else { return }
        let point = target.convert(event.locationInWindow, from: nil)
        let index = target.characterIndexForInsertion(at: point)
        let startID = preservingAnchor ? anchor?.id : origin.selectionID
        let startOffset = preservingAnchor ? anchor?.offset : initialRange.location
        guard let startID, let startOffset, let start = indexes[startID], let end = indexes[target.selectionID] else { return }
        let backwards = end < start || (end == start && index < startOffset)
        if !preservingAnchor {
            anchor = Position(id: origin.selectionID, offset: backwards ? NSMaxRange(initialRange) : initialRange.location)
        }
        let range = target.selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: granularity)
        extend(to: Position(id: target.selectionID, offset: backwards ? range.location : NSMaxRange(range)))
    }

    private func distance(to view: NSView, event: NSEvent) -> CGFloat {
        let point = view.convert(event.locationInWindow, from: nil)
        let dx = max(view.bounds.minX - point.x, point.x - view.bounds.maxX, 0)
        let dy = max(view.bounds.minY - point.y, point.y - view.bounds.maxY, 0)
        return dx * dx + dy * dy
    }

    func range(for id: String) -> NSRange? {
        guard let anchor, let extent,
              let startIndex = indexes[anchor.id],
              let endIndex = indexes[extent.id],
              let index = indexes[id] else { return nil }
        let forward = startIndex < endIndex || (startIndex == endIndex && anchor.offset <= extent.offset)
        let lower = forward ? anchor : extent
        let upper = forward ? extent : anchor
        let lowerIndex = min(startIndex, endIndex)
        let upperIndex = max(startIndex, endIndex)
        guard (lowerIndex ... upperIndex).contains(index) else { return nil }
        let length = rows[index].text.utf16.count
        let start = index == lowerIndex ? min(lower.offset, length) : 0
        let end = index == upperIndex ? min(upper.offset, length) : length
        return NSRange(location: start, length: max(0, end - start))
    }

    var selectedText: String? {
        guard let anchor, let extent, anchor.id != extent.id else { return nil }
        return rows.compactMap { row in
            range(for: row.id).map { (row.text as NSString).substring(with: $0) }
        }.joined(separator: "\n")
    }

    @discardableResult
    func selectAll() -> Bool {
        guard let first = rows.first, let last = rows.last else { return false }
        begin(at: Position(id: first.id, offset: 0))
        extend(to: Position(id: last.id, offset: last.text.utf16.count))
        return true
    }

    func finish() {
        guard extent != nil else { return }
        for view in views.allObjects {
            apply(to: view)
        }
    }

    func clear(excluding origin: SelectableTextView? = nil) {
        anchor = nil
        extent = nil
        for view in views.allObjects where view !== origin {
            view.setSelectedRange(NSRange(location: 0, length: 0))
        }
    }

    private func apply(to view: SelectableTextView) {
        view.setSelectedRange(range(for: view.selectionID) ?? NSRange(location: 0, length: 0))
    }
}
