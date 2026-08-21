import AppKit
import SwiftUI

struct MainSidebarHelpMenuButton: NSViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let onOpenMCP: () -> Void

    func makeCoordinator() -> MainSidebarHelpMenuCoordinator {
        MainSidebarHelpMenuCoordinator(onOpenMCP: onOpenMCP)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(MainSidebarHelpMenuCoordinator.toggleMenu))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        context.coordinator.button = button
        configure(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.update(onOpenMCP: onOpenMCP)
        configure(button)
    }

    static func dismantleNSView(_: NSButton, coordinator: MainSidebarHelpMenuCoordinator) {
        coordinator.dismissMenu()
    }

    private func configure(_ button: NSButton) {
        _ = dynamicTypeSize
        let font = NSFont.preferredFont(forTextStyle: .body)
        button.image = NSImage(
            systemSymbolName: "questionmark.circle",
            accessibilityDescription: L10n.help
        )?.withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular))
        button.setAccessibilityLabel(L10n.help)
    }
}
