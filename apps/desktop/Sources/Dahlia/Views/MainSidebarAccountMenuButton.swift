import AppKit
import SwiftUI

struct MainSidebarAccountMenuButton: NSViewRepresentable {
    @State private var accountController = DahliaCloudAccountController.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let vaults: [VaultRecord]
    let currentVault: VaultRecord?
    let connections: [DahliaAccountConnection]
    let currentConnectionID: UUID?
    let isLocalAccount: Bool
    let isLocalAccountAvailable: Bool
    let onSelectVault: (VaultRecord) -> Void
    let onOpenSettings: (SettingsCategory?) -> Void
    let onSelectAccount: (DahliaAccountConnection?) -> Void
    let onAccountAction: () -> Void

    func makeCoordinator() -> MainSidebarAccountMenuCoordinator {
        MainSidebarAccountMenuCoordinator(
            vaults: vaults,
            currentVault: currentVault,
            connections: connections,
            accountSelection: accountSelection,
            onSelectVault: onSelectVault,
            onOpenSettings: onOpenSettings,
            onSelectAccount: onSelectAccount,
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
            connections: connections,
            accountSelection: accountSelection,
            onSelectVault: onSelectVault,
            onOpenSettings: onOpenSettings,
            onSelectAccount: onSelectAccount,
            onAccountAction: onAccountAction
        )
        configure(button)
    }

    static func dismantleNSView(_: NSButton, coordinator: MainSidebarAccountMenuCoordinator) {
        coordinator.dismissMenu()
    }

    private func configure(_ button: NSButton) {
        _ = dynamicTypeSize
        let currentConnection = connections.first { $0.id == currentConnectionID }
        let accountTitle = isLocalAccount
            ? L10n.localAccount
            : currentConnection?.displayName ?? L10n.dahliaNotSignedIn
        let vaultTitle = currentVault?.name ?? L10n.noVaultSelected
        let progress = currentConnectionID.flatMap { accountController.syncProgress[$0] }
        let syncTitle: String? = if isLocalAccount {
            nil
        } else if accountController.syncProgressUnavailable {
            L10n.syncProgressUnavailable
        } else {
            progress?.summary
        }
        button.attributedTitle = Self.footerTitle(
            accountName: accountTitle,
            vaultName: vaultTitle,
            syncSummary: progress?.state == .synced ? nil : syncTitle
        )
        let font = NSFont.preferredFont(forTextStyle: .body)
        if !isLocalAccount, let currentConnectionID {
            let state = accountController.syncStates[currentConnectionID] ?? .pending
            button.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: state.title)?
                .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular)
                    .applying(.init(paletteColors: [state == .synced ? .systemGreen : .secondaryLabelColor, .secondaryLabelColor])))
        } else {
            button.image = NSImage(systemSymbolName: isLocalAccount ? "person.2" : "icloud.slash", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular))
        }
        button.toolTip = syncTitle
        button.setAccessibilityLabel("\(L10n.account), \(accountTitle); \(L10n.currentVault), \(vaultTitle); \(syncTitle ?? "")")
    }

    private var accountSelection: MainSidebarAccountSelection {
        MainSidebarAccountSelection(
            connectionID: currentConnectionID,
            isLocal: isLocalAccount,
            isLocalAvailable: isLocalAccountAvailable
        )
    }

    static func footerTitle(accountName: String, vaultName: String, syncSummary: String? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: accountName,
            attributes: [.font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.labelColor]
        ))
        result.append(NSAttributedString(string: "\n"))
        result.append(vaultLine(title: syncSummary.map { "\($0) · \(vaultName)" } ?? vaultName))
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = 6
        paragraphStyle.headIndent = 6
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))
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
