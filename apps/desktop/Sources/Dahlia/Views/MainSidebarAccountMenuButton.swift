import AppKit
import SwiftUI

struct MainSidebarAccountMenuButton: NSViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let vaults: [VaultRecord]
    let currentVault: VaultRecord?
    let onSelectVault: (VaultRecord) -> Void
    let onManageVaults: () -> Void
    let onOpenSettings: () -> Void

    func makeCoordinator() -> MainSidebarAccountMenuCoordinator {
        MainSidebarAccountMenuCoordinator(
            vaults: vaults,
            currentVault: currentVault,
            onSelectVault: onSelectVault,
            onManageVaults: onManageVaults,
            onOpenSettings: onOpenSettings
        )
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(MainSidebarAccountMenuCoordinator.toggleMenu))
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.coordinator.button = button
        configure(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.update(
            vaults: vaults,
            currentVault: currentVault,
            onSelectVault: onSelectVault,
            onManageVaults: onManageVaults,
            onOpenSettings: onOpenSettings
        )
        configure(button)
    }

    static func dismantleNSView(_: NSButton, coordinator: MainSidebarAccountMenuCoordinator) {
        coordinator.dismissMenu()
    }

    private func configure(_ button: NSButton) {
        _ = dynamicTypeSize
        let title = currentVault?.name ?? L10n.noVaultSelected
        button.font = bodyFont
        button.title = title
        button.image = NSImage(
            systemSymbolName: "externaldrive",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: bodyFont.pointSize, weight: .regular))
        button.setAccessibilityLabel("\(L10n.currentVault), \(title)")
    }

    private var bodyFont: NSFont {
        .preferredFont(forTextStyle: .body)
    }
}
