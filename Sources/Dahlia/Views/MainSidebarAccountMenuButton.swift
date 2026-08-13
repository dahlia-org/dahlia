import AppKit
import SwiftUI

struct MainSidebarAccountMenuButton: NSViewRepresentable {
    let vaults: [VaultRecord]
    let currentVault: VaultRecord?
    let onSelectVault: (VaultRecord) -> Void
    let onManageVaults: () -> Void
    let onOpenMCP: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelectVault: onSelectVault,
            onManageVaults: onManageVaults,
            onOpenMCP: onOpenMCP
        )
    }

    func makeNSView(context: Context) -> UpwardMenuButton {
        let button = UpwardMenuButton(frame: .zero)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        configure(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: UpwardMenuButton, context: Context) {
        context.coordinator.onSelectVault = onSelectVault
        context.coordinator.onManageVaults = onManageVaults
        context.coordinator.onOpenMCP = onOpenMCP
        configure(button, coordinator: context.coordinator)
    }

    private func configure(_ button: UpwardMenuButton, coordinator: Coordinator) {
        let menu = NSMenu()
        let title = currentVault?.name ?? L10n.noVaultSelected

        let vaultMenu = NSMenu(title: L10n.switchVault)
        coordinator.vaultsByTag.removeAll(keepingCapacity: true)
        for (index, vault) in vaults.enumerated() {
            let item = NSMenuItem(
                title: vault.name,
                action: #selector(Coordinator.performAction(_:)),
                keyEquivalent: ""
            )
            let tag = Coordinator.firstVaultTag + index
            item.tag = tag
            item.target = coordinator
            item.state = vault.id == currentVault?.id ? .on : .off
            item.isEnabled = vault.id != currentVault?.id
            coordinator.vaultsByTag[tag] = vault
            vaultMenu.addItem(item)
        }
        vaultMenu.addItem(.separator())
        vaultMenu.addItem(coordinator.actionItem(
            title: L10n.manageVaults,
            image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil),
            tag: Coordinator.manageVaultsTag
        ))

        let switchVaultItem = NSMenuItem(title: L10n.switchVault, action: nil, keyEquivalent: "")
        switchVaultItem.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
        switchVaultItem.submenu = vaultMenu
        menu.addItem(switchVaultItem)

        menu.addItem(coordinator.actionItem(
            title: L10n.mcpSettings,
            image: Self.mcpIcon,
            tag: Coordinator.mcpSettingsTag
        ))

        button.title = title
        button.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
        button.trackingMenu = menu
        button.setAccessibilityLabel("\(L10n.currentVault), \(title)")
    }

    @MainActor
    final class Coordinator: NSObject {
        static let manageVaultsTag = 1
        static let mcpSettingsTag = 2
        static let firstVaultTag = 1000

        var onSelectVault: (VaultRecord) -> Void
        var onManageVaults: () -> Void
        var onOpenMCP: () -> Void
        var vaultsByTag: [Int: VaultRecord] = [:]

        init(
            onSelectVault: @escaping (VaultRecord) -> Void,
            onManageVaults: @escaping () -> Void,
            onOpenMCP: @escaping () -> Void
        ) {
            self.onSelectVault = onSelectVault
            self.onManageVaults = onManageVaults
            self.onOpenMCP = onOpenMCP
        }

        func actionItem(title: String, image: NSImage?, tag: Int) -> NSMenuItem {
            let item = NSMenuItem(
                title: title,
                action: #selector(performAction(_:)),
                keyEquivalent: ""
            )
            item.image = image
            item.tag = tag
            item.target = self
            return item
        }

        @objc
        func performAction(_ sender: NSMenuItem) {
            switch sender.tag {
            case Self.manageVaultsTag:
                onManageVaults()
            case Self.mcpSettingsTag:
                onOpenMCP()
            default:
                guard let vault = vaultsByTag[sender.tag] else { return }
                onSelectVault(vault)
            }
        }
    }

    @MainActor private static let mcpIcon: NSImage? = {
        guard let source = Bundle.appModule.image(forResource: "MCPLogo"),
              let icon = source.copy() as? NSImage else {
            return nil
        }
        icon.size = NSSize(width: 16, height: 16)
        icon.isTemplate = true
        return icon
    }()
}

final class UpwardMenuButton: NSButton {
    var trackingMenu: NSMenu?

    override func mouseDown(with _: NSEvent) {
        showTrackingMenu()
    }

    override func performClick(_: Any?) {
        showTrackingMenu()
    }

    private func showTrackingMenu() {
        guard let trackingMenu, let window else { return }
        trackingMenu.update()

        let frameOnScreen = window.convertToScreen(convert(bounds, to: nil))
        trackingMenu.minimumWidth = max(trackingMenu.minimumWidth, frameOnScreen.width)
        trackingMenu.popUp(
            positioning: nil,
            at: NSPoint(x: frameOnScreen.minX, y: frameOnScreen.maxY + trackingMenu.size.height),
            in: nil
        )
    }
}
