import AppKit
import SwiftUI

struct MainSidebarAccountMenuButton: NSViewRepresentable {
    let vaults: [VaultRecord]
    let currentVault: VaultRecord?
    let onSelectVault: (VaultRecord) -> Void
    let onManageVaults: () -> Void
    let onOpenMCP: () -> Void

    func makeCoordinator() -> MainSidebarAccountMenuCoordinator {
        MainSidebarAccountMenuCoordinator(
            vaults: vaults,
            currentVault: currentVault,
            onSelectVault: onSelectVault,
            onManageVaults: onManageVaults,
            onOpenMCP: onOpenMCP
        )
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(MainSidebarAccountMenuCoordinator.toggleMenu))
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.font = .systemFont(ofSize: DahliaDesign.sidebarFontSize)
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
            onOpenMCP: onOpenMCP
        )
        configure(button)
    }

    static func dismantleNSView(_: NSButton, coordinator: MainSidebarAccountMenuCoordinator) {
        coordinator.dismissMenu()
    }

    private func configure(_ button: NSButton) {
        let title = currentVault?.name ?? L10n.noVaultSelected
        button.title = title
        button.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
        button.setAccessibilityLabel("\(L10n.currentVault), \(title)")
    }
}
