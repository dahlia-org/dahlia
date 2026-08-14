import AppKit
import SwiftUI

/// `HSplitView` の分割位置を保存し、設定画面の再表示時に復元する。
struct SplitViewAutosaveView: NSViewRepresentable {
    let widthDefaultsKey: String

    func makeCoordinator() -> Coordinator {
        Coordinator(widthDefaultsKey: widthDefaultsKey)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configureWhenAttached(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
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
        private let widthDefaultsKey: String
        private weak var splitView: NSSplitView?

        init(widthDefaultsKey: String) {
            self.widthDefaultsKey = widthDefaultsKey
        }

        func attach(to splitView: NSSplitView) {
            guard self.splitView !== splitView else { return }
            NotificationCenter.default.removeObserver(self)
            self.splitView = splitView

            if UserDefaults.standard.object(forKey: widthDefaultsKey) != nil {
                splitView.setPosition(UserDefaults.standard.double(forKey: widthDefaultsKey), ofDividerAt: 0)
            }

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(splitViewDidResize),
                name: NSSplitView.didResizeSubviewsNotification,
                object: splitView
            )
        }

        @objc private func splitViewDidResize() {
            guard let width = splitView?.subviews.first?.frame.width else { return }
            UserDefaults.standard.set(width, forKey: widthDefaultsKey)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
