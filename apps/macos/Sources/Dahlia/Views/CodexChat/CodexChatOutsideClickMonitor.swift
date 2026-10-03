import AppKit
import SwiftUI

extension View {
    func codexChatDismissOnOutsideClick(perform action: @escaping () -> Void) -> some View {
        background {
            CodexChatOutsideClickMonitor(onOutsideClick: action)
        }
    }
}

struct CodexChatOutsideClickMonitor: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOutsideClick: onOutsideClick)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.startMonitoring(view: view)
        return view
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        var onOutsideClick: () -> Void

        private var eventMonitor: Any?

        init(onOutsideClick: @escaping () -> Void) {
            self.onOutsideClick = onOutsideClick
        }

        func startMonitoring(view: NSView) {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self, weak view] event in
                guard let self, let view else { return event }
                return handle(event, in: view)
            }
        }

        func handle(_ event: NSEvent, in view: NSView) -> NSEvent {
            guard event.window === view.window else { return event }

            let location = view.convert(event.locationInWindow, from: nil)
            guard !view.bounds.contains(location) else { return event }

            Task { @MainActor [weak self] in
                self?.onOutsideClick()
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
