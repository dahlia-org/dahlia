import AppKit
import SwiftUI

struct ChatRowHoverTracker: NSViewRepresentable {
    @Binding var isHovered: Bool

    func makeNSView(context _: Context) -> ChatRowHoverView {
        ChatRowHoverView()
    }

    func updateNSView(_ view: ChatRowHoverView, context _: Context) {
        view.onHover = { hovered in
            if isHovered != hovered { isHovered = hovered }
        }
        view.scheduleHoverUpdate()
    }

    static func dismantleNSView(_ view: ChatRowHoverView, coordinator _: ()) {
        view.invalidate()
    }
}

@MainActor
final class ChatRowHoverView: NSView {
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var hoverTask: Task<Void, Never>?

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds.intersection(visibleRect), options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
        scheduleHoverUpdate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleHoverUpdate()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        scheduleHoverUpdate()
    }

    override func mouseEntered(with _: NSEvent) { scheduleHoverUpdate() }
    override func mouseExited(with _: NSEvent) { scheduleHoverUpdate() }

    func containsPointer(at screenPoint: NSPoint) -> Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return bounds.intersection(visibleRect).contains(convert(window.convertPoint(fromScreen: screenPoint), from: nil))
    }

    func scheduleHoverUpdate() {
        hoverTask?.cancel()
        // Publish after AppKit/SwiftUI layout, using current geometry even if the pointer has not moved.
        hoverTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            onHover?(containsPointer(at: NSEvent.mouseLocation))
        }
    }

    func invalidate() {
        hoverTask?.cancel()
        hoverTask = nil
        onHover = nil
    }
}
