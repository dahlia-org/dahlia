import AppKit
import SwiftUI

/// The footer's gear: opens the menu with quick language and appearance changes and the full Settings.
struct MainSidebarAccountMenuButton: NSViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let onOpenSettings: () -> Void

    func makeCoordinator() -> MainSidebarAccountMenuCoordinator {
        MainSidebarAccountMenuCoordinator(onOpenSettings: onOpenSettings)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(MainSidebarAccountMenuCoordinator.toggleMenu))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        context.coordinator.button = button
        configure(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        // An AppKit button ignores SwiftUI's `.disabled`, such as the footer's while recording.
        button.isEnabled = context.environment.isEnabled
        context.coordinator.update(onOpenSettings: onOpenSettings)
        configure(button)
    }

    static func dismantleNSView(_: NSButton, coordinator: MainSidebarAccountMenuCoordinator) {
        coordinator.dismissMenu()
    }

    private func configure(_ button: NSButton) {
        _ = dynamicTypeSize
        button.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: L10n.settings
        )?.withSymbolConfiguration(.init(pointSize: NSFont.dahliaBody.pointSize, weight: .regular))
        button.setAccessibilityLabel(L10n.settings)
    }
}
