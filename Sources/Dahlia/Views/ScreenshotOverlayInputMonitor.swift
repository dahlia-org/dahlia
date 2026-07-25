import AppKit
import SwiftUI

struct ScreenshotOverlayInputMonitor: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.startMonitoring(view: view)
        return view
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.onDismiss = onDismiss
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        private static let escapeKeyCode: UInt16 = 53

        var onDismiss: () -> Void

        private var eventMonitor: Any?

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
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
                guard event.keyCode == Self.escapeKeyCode else { return event }
                onDismiss()
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
