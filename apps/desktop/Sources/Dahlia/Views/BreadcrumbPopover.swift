import AppKit
import SwiftUI

/// Hover owns dismissal; a submenu must not intercept clicks on its parent rows.
struct BreadcrumbPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    @ViewBuilder let content: Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context _: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(isPresented: isPresented, content: content, anchor: view, arrowEdge: arrowEdge)
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.popover.performClose(nil)
        coordinator.popover.contentViewController = nil
    }

    @MainActor final class Coordinator {
        let popover = NSPopover()

        func update(isPresented: Bool, content: Content, anchor: NSView, arrowEdge: Edge) {
            guard isPresented else {
                popover.performClose(nil)
                popover.contentViewController = nil
                return
            }
            if let controller = popover.contentViewController as? NSHostingController<Content> {
                controller.rootView = content
            } else {
                let controller = NSHostingController(rootView: content)
                controller.sizingOptions = [.preferredContentSize]
                popover.contentViewController = controller
            }
            guard !popover.isShown, anchor.window != nil else { return }
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: arrowEdge == .trailing ? .maxX : .minY)
        }

        init() {
            popover.behavior = .applicationDefined
            popover.animates = false
        }
    }
}
