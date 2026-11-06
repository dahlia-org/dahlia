import AppKit
import SwiftUI

struct MainSidebarAccountMenuButton: NSViewRepresentable {
    @State private var accountController = DahliaCloudAccountController.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let connections: [DahliaAccountConnection]
    let currentConnectionID: UUID?
    let isLocalAccount: Bool
    var databricksAccounts: [DatabricksConnection] = []
    var currentDatabricksAccountID: UUID?
    let onOpenSettings: (SettingsCategory?) -> Void
    let onSelectAccount: (DahliaAccountConnection?) -> Void
    var onSelectDatabricksAccount: (UUID) -> Void = { _ in }
    let onAccountAction: () -> Void

    func makeCoordinator() -> MainSidebarAccountMenuCoordinator {
        MainSidebarAccountMenuCoordinator(
            connections: connections,
            accountSelection: accountSelection,
            onOpenSettings: onOpenSettings,
            onSelectAccount: onSelectAccount,
            onSelectDatabricksAccount: onSelectDatabricksAccount,
            onAccountAction: onAccountAction
        )
    }

    func makeNSView(context: Context) -> MainSidebarAccountButton {
        let button = MainSidebarAccountButton(frame: .zero)
        button.target = context.coordinator
        button.action = #selector(MainSidebarAccountMenuCoordinator.toggleMenu)
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

    func updateNSView(_ button: MainSidebarAccountButton, context: Context) {
        // An AppKit button ignores SwiftUI's `.disabled`, such as the footer's while recording.
        button.isEnabled = context.environment.isEnabled
        context.coordinator.update(
            connections: connections,
            accountSelection: accountSelection,
            onOpenSettings: onOpenSettings,
            onSelectAccount: onSelectAccount,
            onSelectDatabricksAccount: onSelectDatabricksAccount,
            onAccountAction: onAccountAction
        )
        configure(button)
    }

    static func dismantleNSView(_: MainSidebarAccountButton, coordinator: MainSidebarAccountMenuCoordinator) {
        coordinator.dismissMenu()
    }

    private func configure(_ button: MainSidebarAccountButton) {
        _ = dynamicTypeSize
        let currentConnection = connections.first { $0.id == currentConnectionID }
        let databricks = currentDatabricksAccountID.map { id in
            Self.databricksFooterLines(databricksAccounts.first { $0.id == id })
        }
        let accountTitle = databricks?.title
            ?? (isLocalAccount ? L10n.localAccount : currentConnection?.displayName ?? L10n.dahliaNotSignedIn)
        let progress = currentConnectionID.flatMap { accountController.syncProgress[$0] }
        let syncTitle: String? = if let databricks {
            databricks.detail
        } else if isLocalAccount {
            nil
        } else if accountController.syncProgressUnavailable {
            L10n.syncProgressUnavailable
        } else {
            progress?.summary
        }
        button.attributedTitle = Self.footerTitle(
            accountName: accountTitle,
            syncSummary: progress?.state == .synced ? nil : syncTitle
        )
        let font = NSFont.preferredFont(forTextStyle: .body)
        if !isLocalAccount, let currentConnectionID {
            let state = accountController.syncStates[currentConnectionID] ?? .pending
            let icon = NSImage(systemSymbolName: state.symbol, accessibilityDescription: state.title)?
                .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular)
                    .applying(.init(paletteColors: [state == .synced ? .systemGreen : .secondaryLabelColor, .secondaryLabelColor])))
            button.setIcon(icon, animated: progress?.isSyncing == true)
        } else {
            let icon = if currentDatabricksAccountID != nil {
                Self.sized(.databricksLogo, to: font.pointSize)
            } else {
                NSImage(systemSymbolName: isLocalAccount ? "person.2" : "icloud.slash", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular))
            }
            button.setIcon(icon, animated: false)
        }
        button.toolTip = syncTitle
        button.setAccessibilityLabel("\(L10n.account), \(accountTitle); \(syncTitle ?? "")")
    }

    private var accountSelection: MainSidebarAccountSelection {
        MainSidebarAccountSelection(
            connectionID: currentConnectionID,
            isLocal: isLocalAccount,
            databricksAccounts: databricksAccounts,
            currentDatabricksID: currentDatabricksAccountID
        )
    }

    /// A Databricks account's footer: the workspace over its user's email.
    static func databricksFooterLines(_ connection: DatabricksConnection?) -> (title: String, detail: String?) {
        guard let connection else { return (L10n.databricks, nil) }
        return (connection.workspaceName, connection.email)
    }

    private static func sized(_ image: NSImage, to pointSize: CGFloat) -> NSImage {
        let sized = image.copy() as? NSImage ?? image
        sized.size = NSSize(width: pointSize, height: pointSize)
        return sized
    }

    static func footerTitle(accountName: String, syncSummary: String? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: accountName,
            attributes: [.font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.labelColor]
        ))
        if let syncSummary {
            result.append(NSAttributedString(
                string: "\n" + syncSummary,
                attributes: [.font: NSFont.preferredFont(forTextStyle: .footnote), .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = 6
        paragraphStyle.headIndent = 6
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))
        return result
    }

}
