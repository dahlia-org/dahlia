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
    var widthSourceID = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(
            width: width,
            pane: pane,
            widthSourceID: widthSourceID,
            onWidthChange: onWidthChange
        )
    }

    func makeNSView(context: Context) -> SplitViewAttachmentTrackingView {
        let view = SplitViewAttachmentTrackingView()
        view.onAttachmentChange = { view in
            Self.configureAttachment(of: view, coordinator: context.coordinator)
        }
        view.scheduleAttachmentUpdate()
        return view
    }

    func updateNSView(_ nsView: SplitViewAttachmentTrackingView, context: Context) {
        context.coordinator.update(
            width: width,
            widthSourceID: widthSourceID,
            onWidthChange: onWidthChange
        )
        nsView.scheduleAttachmentUpdate()
    }

    static func dismantleNSView(_ nsView: SplitViewAttachmentTrackingView, coordinator: Coordinator) {
        nsView.invalidate()
        coordinator.detach()
    }

    private static func configureAttachment(
        of view: SplitViewAttachmentTrackingView,
        coordinator: Coordinator
    ) {
        if let splitView = enclosingSplitView(for: view) {
            coordinator.attach(to: splitView, markerView: view)
        } else {
            coordinator.detach()
        }
    }

    private static func enclosingSplitView(for view: NSView) -> NSSplitView? {
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
        private var widthSourceID: Int
        private let pane: Pane
        private var onWidthChange: (CGFloat) -> Void
        private let resizeDelay: Duration
        private let onResizeTaskCompletion: (() -> Void)?
        private weak var splitView: NSSplitView?
        private weak var markerView: NSView?
        private var resizeTask: Task<Void, Never>?
        private var pendingWidth: CGFloat?

        init(
            width: CGFloat,
            pane: Pane = .first,
            widthSourceID: Int = 0,
            resizeDelay: Duration = .milliseconds(50),
            onResizeTaskCompletion: (() -> Void)? = nil,
            onWidthChange: @escaping (CGFloat) -> Void
        ) {
            self.width = width
            self.widthSourceID = widthSourceID
            self.pane = pane
            self.resizeDelay = resizeDelay
            self.onResizeTaskCompletion = onResizeTaskCompletion
            self.onWidthChange = onWidthChange
        }

        func update(
            width: CGFloat,
            widthSourceID: Int = 0,
            onWidthChange: @escaping (CGFloat) -> Void
        ) {
            if widthSourceID != self.widthSourceID || abs(width - self.width) > Self.widthTolerance {
                resizeTask?.cancel()
                resizeTask = nil
                pendingWidth = nil
            }
            self.width = width
            self.widthSourceID = widthSourceID
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
            resizeTask?.cancel()
            resizeTask = nil
            pendingWidth = nil
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
                  abs(trackedPane.frame.width - targetWidth) > Self.widthTolerance else { return }
            let position = switch pane {
            case .first:
                targetWidth
            case .last:
                splitView.bounds.width - targetWidth - splitView.dividerThickness
            }
            splitView.setPosition(position, ofDividerAt: dividerIndex)
        }

        @objc private func splitViewDidResize() {
            guard markerIsInTrackedPane, let currentTrackedPane = trackedPane else { return }
            resizeTask?.cancel()
            let resizedWidth = currentTrackedPane.frame.width
            guard abs(resizedWidth - width) > Self.widthTolerance else {
                resizeTask = nil
                pendingWidth = nil
                return
            }
            pendingWidth = resizedWidth
            resizeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { onResizeTaskCompletion?() }
                try? await Task.sleep(for: resizeDelay)
                guard !Task.isCancelled,
                      markerIsInTrackedPane,
                      let trackedPane else { return }
                let resizedWidth = trackedPane.frame.width
                pendingWidth = nil
                resizeTask = nil
                guard abs(resizedWidth - width) > Self.widthTolerance else { return }
                width = resizedWidth
                onWidthChange(resizedWidth)
            }
        }

        private var targetWidth: CGFloat {
            pendingWidth ?? width
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
            resizeTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }
    }
}
