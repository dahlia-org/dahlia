import AppKit
import SwiftUI

/// A read-only hover preview with no popover arrow or activation change.
struct CodexChatThreadHoverPanel<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context _: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        if isPresented {
            context.coordinator.show(content().dahliaAppearance(), above: view)
        } else {
            context.coordinator.dismiss()
        }
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    @MainActor
    final class Coordinator {
        private var panel: NSPanel?

        func show(_ content: some View, above anchor: NSView) {
            guard let window = anchor.window, let screen = window.screen else { return }
            let hosting = NSHostingView(rootView: content.fixedSize())
            let size = hosting.fittingSize
            let panel = panel ?? NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
            )
            panel.contentView = hosting
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = true
            panel.isReleasedWhenClosed = false
            let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            let proposedY = rect.maxY + 6
            let y = proposedY + size.height <= bounds.maxY ? proposedY : rect.minY - size.height - 6
            let origin = NSPoint(
                x: min(max(rect.midX - size.width / 2, bounds.minX), bounds.maxX - size.width),
                y: min(max(y, bounds.minY), bounds.maxY - size.height)
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
            self.panel = panel
        }

        func dismiss() {
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.close()
            self.panel = nil
        }
    }
}
