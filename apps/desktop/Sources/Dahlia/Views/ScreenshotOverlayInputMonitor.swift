import AppKit
import SwiftUI

struct ScreenshotOverlayInputMonitor: NSViewRepresentable {
    let onDismiss: () -> Void
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}
    var topTrailingProtectedSize: CGSize = .zero
    var bottomCenterProtectedSize: CGSize = .zero

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onDismiss: onDismiss,
            onPrevious: onPrevious,
            onNext: onNext,
            topTrailingProtectedSize: topTrailingProtectedSize,
            bottomCenterProtectedSize: bottomCenterProtectedSize
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.startMonitoring(view: view)
        return view
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.onDismiss = onDismiss
        context.coordinator.onPrevious = onPrevious
        context.coordinator.onNext = onNext
        context.coordinator.topTrailingProtectedSize = topTrailingProtectedSize
        context.coordinator.bottomCenterProtectedSize = bottomCenterProtectedSize
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }
}

struct ScreenshotOverlayDismissalArea: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeNSView(context _: Context) -> DismissalView {
        DismissalView(onDismiss: onDismiss)
    }

    func updateNSView(_ view: DismissalView, context _: Context) {
        view.onDismiss = onDismiss
    }

    @MainActor
    final class DismissalView: NSView {
        var onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func mouseDown(with _: NSEvent) {
            onDismiss()
        }

        override func rightMouseDown(with _: NSEvent) {
            onDismiss()
        }

        override func otherMouseDown(with _: NSEvent) {
            onDismiss()
        }
    }
}

extension ScreenshotOverlayInputMonitor {
    @MainActor
    final class Coordinator {
        private static let escapeKeyCode: UInt16 = 53
        private static let leftArrowKeyCode: UInt16 = 123
        private static let rightArrowKeyCode: UInt16 = 124

        var onDismiss: () -> Void
        var onPrevious: () -> Void
        var onNext: () -> Void
        var topTrailingProtectedSize: CGSize
        var bottomCenterProtectedSize: CGSize

        private var eventMonitor: Any?

        init(
            onDismiss: @escaping () -> Void,
            onPrevious: @escaping () -> Void = {},
            onNext: @escaping () -> Void = {},
            topTrailingProtectedSize: CGSize = .zero,
            bottomCenterProtectedSize: CGSize = .zero
        ) {
            self.onDismiss = onDismiss
            self.onPrevious = onPrevious
            self.onNext = onNext
            self.topTrailingProtectedSize = topTrailingProtectedSize
            self.bottomCenterProtectedSize = bottomCenterProtectedSize
        }

        func startMonitoring(view: NSView) {
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self, weak view] event in
                guard let self, let view else { return event }
                return handle(event, in: view)
            }
        }

        func handle(_ event: NSEvent, in view: NSView) -> NSEvent? {
            guard event.window === view.window else { return event }

            switch event.type {
            case .keyDown:
                switch event.keyCode {
                case Self.escapeKeyCode:
                    onDismiss()
                case Self.leftArrowKeyCode:
                    onPrevious()
                case Self.rightArrowKeyCode:
                    onNext()
                default:
                    return event
                }
                // 端で移動できない場合も、背後の一覧へ矢印キーを漏らさない。
                return nil
            case .rightMouseDown, .otherMouseDown:
                break
            default:
                return event
            }

            let location = view.convert(event.locationInWindow, from: nil)
            guard !view.bounds.contains(location) else { return event }
            if isInProtectedRegion(event, view: view) { return event }

            let dismiss = onDismiss
            // Let the clicked control finish handling the event before removing the overlay.
            Task { @MainActor in
                dismiss()
            }
            return event
        }

        private func isInProtectedRegion(_ event: NSEvent, view: NSView) -> Bool {
            guard let contentView = view.window?.contentView else { return false }
            let location = contentView.convert(event.locationInWindow, from: nil)
            let topTrailingRegion = CGRect(
                x: contentView.bounds.maxX - topTrailingProtectedSize.width,
                y: contentView.bounds.maxY - topTrailingProtectedSize.height,
                width: topTrailingProtectedSize.width,
                height: topTrailingProtectedSize.height
            )
            let bottomCenterRegion = CGRect(
                x: contentView.bounds.midX - bottomCenterProtectedSize.width / 2,
                y: contentView.bounds.minY,
                width: bottomCenterProtectedSize.width,
                height: bottomCenterProtectedSize.height
            )
            return topTrailingRegion.contains(location) || bottomCenterRegion.contains(location)
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
