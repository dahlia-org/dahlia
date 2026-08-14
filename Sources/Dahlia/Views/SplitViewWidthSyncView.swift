import SwiftUI

/// `HSplitView` の分割位置を共有状態と同期する。
struct SplitViewWidthSyncView: NSViewRepresentable {
    enum Pane {
        case first
        case last
    }

    let width: CGFloat
    let onWidthChange: (CGFloat) -> Void
    var pane: Pane = .first

    func makeCoordinator() -> Coordinator {
        Coordinator(width: width, pane: pane, onWidthChange: onWidthChange)
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

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private func configureWhenAttached(_ view: NSView, coordinator: Coordinator) {
        Task { @MainActor [weak view] in
            guard let view, let splitView = enclosingSplitView(for: view) else { return }
            coordinator.attach(to: splitView, markerView: view)
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
        private let pane: Pane
        private var onWidthChange: (CGFloat) -> Void
        private weak var splitView: NSSplitView?
        private weak var markerView: NSView?

        init(
            width: CGFloat,
            pane: Pane = .first,
            onWidthChange: @escaping (CGFloat) -> Void
        ) {
            self.width = width
            self.pane = pane
            self.onWidthChange = onWidthChange
        }

        func update(width: CGFloat, onWidthChange: @escaping (CGFloat) -> Void) {
            self.width = width
            self.onWidthChange = onWidthChange
            applyWidthIfNeeded()
        }

        func attach(to splitView: NSSplitView, markerView: NSView) {
            splitView.wantsLayer = true
            splitView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            if self.splitView !== splitView {
                detach()
                self.splitView = splitView
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(splitViewDidResize),
                    name: NSSplitView.didResizeSubviewsNotification,
                    object: splitView
                )
            }
            self.markerView = markerView
            applyWidthIfNeeded()
        }

        func detach() {
            if let splitView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSSplitView.didResizeSubviewsNotification,
                    object: splitView
                )
            }
            splitView = nil
            markerView = nil
        }

        private func applyWidthIfNeeded() {
            guard markerIsInTrackedPane,
                  let splitView,
                  let trackedPane,
                  let dividerIndex,
                  abs(trackedPane.frame.width - width) > Self.widthTolerance else { return }
            let position = switch pane {
            case .first:
                width
            case .last:
                splitView.bounds.width - width - splitView.dividerThickness
            }
            splitView.setPosition(position, ofDividerAt: dividerIndex)
        }

        @objc private func splitViewDidResize() {
            guard markerIsInTrackedPane,
                  let trackedPane else { return }
            let resizedWidth = trackedPane.frame.width
            guard abs(resizedWidth - width) > Self.widthTolerance else { return }
            onWidthChange(resizedWidth)
        }

        private var trackedPane: NSView? {
            switch pane {
            case .first:
                splitView?.subviews.first
            case .last:
                splitView?.subviews.last
            }
        }

        private var dividerIndex: Int? {
            guard let splitView, splitView.subviews.count > 1 else { return nil }
            return switch pane {
            case .first:
                0
            case .last:
                splitView.subviews.count - 2
            }
        }

        private var markerIsInTrackedPane: Bool {
            guard let markerView,
                  let trackedPane else { return false }
            return markerView === trackedPane || markerView.isDescendant(of: trackedPane)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
