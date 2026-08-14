import SwiftUI

/// `HSplitView` の分割位置を共有状態と同期する。
struct SplitViewWidthSyncView: NSViewRepresentable {
    let width: CGFloat
    let onWidthChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(width: width, onWidthChange: onWidthChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWhenAttached(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(width: width, onWidthChange: onWidthChange)
        configureWhenAttached(nsView, coordinator: context.coordinator)
    }

    private func configureWhenAttached(_ view: NSView, coordinator: Coordinator) {
        Task { @MainActor [weak view] in
            guard let view, let splitView = enclosingSplitView(for: view) else { return }
            coordinator.attach(to: splitView)
        }
    }

    private func enclosingSplitView(for view: NSView) -> NSSplitView? {
        var ancestor = view.superview
        while let currentView = ancestor {
            if let splitView = currentView as? NSSplitView {
                return splitView
            }
            ancestor = currentView.superview
        }
        return nil
    }

    @MainActor
    final class Coordinator: NSObject {
        private static let widthTolerance: CGFloat = 0.5

        private var width: CGFloat
        private var onWidthChange: (CGFloat) -> Void
        private weak var splitView: NSSplitView?

        init(width: CGFloat, onWidthChange: @escaping (CGFloat) -> Void) {
            self.width = width
            self.onWidthChange = onWidthChange
        }

        func update(width: CGFloat, onWidthChange: @escaping (CGFloat) -> Void) {
            self.width = width
            self.onWidthChange = onWidthChange
            applyWidthIfNeeded()
        }

        func attach(to splitView: NSSplitView) {
            splitView.wantsLayer = true
            splitView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            if self.splitView !== splitView {
                if let observedSplitView = self.splitView {
                    NotificationCenter.default.removeObserver(
                        self,
                        name: NSSplitView.didResizeSubviewsNotification,
                        object: observedSplitView
                    )
                }
                self.splitView = splitView
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(splitViewDidResize),
                    name: NSSplitView.didResizeSubviewsNotification,
                    object: splitView
                )
            }
            applyWidthIfNeeded()
        }

        private func applyWidthIfNeeded() {
            guard let splitView,
                  splitView.subviews.count > 1,
                  let currentWidth = splitView.subviews.first?.frame.width,
                  abs(currentWidth - width) > Self.widthTolerance else { return }
            splitView.setPosition(width, ofDividerAt: 0)
        }

        @objc private func splitViewDidResize() {
            guard let resizedWidth = splitView?.subviews.first?.frame.width,
                  abs(resizedWidth - width) > Self.widthTolerance else { return }
            onWidthChange(resizedWidth)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
