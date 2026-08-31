import AppKit
import SwiftUI

struct MainSidebarAccountMenuButton: NSViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let vaults: [VaultRecord]
    let currentVault: VaultRecord?
    let account: DahliaCloudAccount?
    let accountOrigin: String?
    let isCloudAccount: Bool?
    let accountSummary: String?
    let onSelectVault: (VaultRecord) -> Void
    let onManageVaults: () -> Void
    let onOpenSettings: (SettingsCategory?) -> Void
    let onAccountAction: () -> Void

    func makeCoordinator() -> MainSidebarAccountMenuCoordinator {
        MainSidebarAccountMenuCoordinator(
            vaults: vaults,
            currentVault: currentVault,
            account: account,
            accountOrigin: accountOrigin,
            isCloudAccount: isCloudAccount,
            onSelectVault: onSelectVault,
            onManageVaults: onManageVaults,
            onOpenSettings: onOpenSettings,
            onAccountAction: onAccountAction
        )
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(MainSidebarAccountMenuCoordinator.toggleMenu))
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.cell?.usesSingleLineMode = false
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.coordinator.button = button
        configure(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.update(
            vaults: vaults,
            currentVault: currentVault,
            account: account,
            accountOrigin: accountOrigin,
            isCloudAccount: isCloudAccount,
            onSelectVault: onSelectVault,
            onManageVaults: onManageVaults,
            onOpenSettings: onOpenSettings,
            onAccountAction: onAccountAction
        )
        configure(button)
    }

    static func dismantleNSView(_: NSButton, coordinator: MainSidebarAccountMenuCoordinator) {
        coordinator.dismissMenu()
    }

    private func configure(_ button: NSButton) {
        _ = dynamicTypeSize
        let accountTitle = accountSummary ?? account?.displayName ?? L10n.dahliaNotSignedIn
        let vaultTitle = currentVault?.name ?? L10n.noVaultSelected
        button.attributedTitle = Self.footerTitle(
            accountName: accountTitle,
            vaultName: vaultTitle
        )
        let font = NSFont.preferredFont(forTextStyle: .body)
        button.image = NSImage(systemSymbolName: accountSystemImage, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular))
        button.setAccessibilityLabel("\(L10n.account), \(accountTitle); \(L10n.currentVault), \(vaultTitle)")
    }

    private var accountSystemImage: String {
        if accountSummary != nil { return "person.2" }
        guard account != nil else { return "icloud.slash" }
        return isCloudAccount == true ? "icloud" : "xserve"
    }

    static func footerTitle(accountName: String, vaultName: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: accountName,
            attributes: [.font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.labelColor]
        ))
        result.append(NSAttributedString(string: "\n"))
        result.append(vaultLine(title: vaultName))
        return result
    }

    private static func vaultLine(title: String) -> NSAttributedString {
        let font = NSFont.preferredFont(forTextStyle: .footnote)
        return NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        )
    }
}
