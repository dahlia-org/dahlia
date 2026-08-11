import AppKit
import SwiftUI

struct MCPModalView: View {
    @Environment(\.dismiss) private var dismiss

    let vaults: [VaultRecord]
    let currentVault: VaultRecord?

    var body: some View {
        NavigationStack {
            MCPSettingsView(
                vaults: vaults,
                currentVault: currentVault
            )
            .navigationTitle(L10n.mcp)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.close, action: dismiss.callAsFunction)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 600)
        .background {
            MCPModalOutsideClickMonitor(onOutsideClick: dismiss.callAsFunction)
        }
    }
}

private struct MCPModalOutsideClickMonitor: NSViewRepresentable {
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
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self, weak view] event in
                guard let self, let view else { return event }
                return handle(event, in: view)
            }
        }

        func handle(_ event: NSEvent, in view: NSView) -> NSEvent? {
            guard let sheetWindow = view.window,
                  event.window === sheetWindow.sheetParent else {
                return event
            }

            onOutsideClick()
            return nil
        }

        func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
