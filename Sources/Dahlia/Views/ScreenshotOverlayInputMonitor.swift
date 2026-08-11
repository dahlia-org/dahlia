import AppKit
import SwiftUI

struct ScreenshotOverlayInputMonitor: NSViewRepresentable {
    let onDismiss: () -> Void
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss, onPrevious: onPrevious, onNext: onNext)
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
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        private static let escapeKeyCode: UInt16 = 53
        private static let leftArrowKeyCode: UInt16 = 123
        private static let rightArrowKeyCode: UInt16 = 124

        var onDismiss: () -> Void
        var onPrevious: () -> Void
        var onNext: () -> Void

        private var eventMonitor: Any?

        init(
            onDismiss: @escaping () -> Void,
            onPrevious: @escaping () -> Void = {},
            onNext: @escaping () -> Void = {}
        ) {
            self.onDismiss = onDismiss
            self.onPrevious = onPrevious
            self.onNext = onNext
        }

        func startMonitoring(view: NSView) {
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
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
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                break
            default:
                return event
            }

            let location = view.convert(event.locationInWindow, from: nil)
            guard !view.bounds.contains(location) else { return event }

            let dismiss = onDismiss
            // Let the clicked control finish handling the event before removing the overlay.
            Task { @MainActor in
                dismiss()
            }
            return event
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
