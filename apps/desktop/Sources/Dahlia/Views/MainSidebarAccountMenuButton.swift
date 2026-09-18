import AppKit
import SwiftUI

struct MainSidebarAccountMenuButton: NSViewRepresentable {
    @State private var accountController = DahliaCloudAccountController.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let workspaces: [WorkspaceRecord]
    let currentWorkspace: WorkspaceRecord?
    let connections: [DahliaAccountConnection]
    let currentConnectionID: UUID?
    let isLocalAccount: Bool
    let isLocalAccountAvailable: Bool
    let onSelectWorkspace: (WorkspaceRecord) -> Void
    let onOpenSettings: (SettingsCategory?) -> Void
    let onSelectAccount: (DahliaAccountConnection?) -> Void
    let onAccountAction: () -> Void

    func makeCoordinator() -> MainSidebarAccountMenuCoordinator {
        MainSidebarAccountMenuCoordinator(
            workspaces: workspaces,
            currentWorkspace: currentWorkspace,
            connections: connections,
            accountSelection: accountSelection,
            onSelectWorkspace: onSelectWorkspace,
            onOpenSettings: onOpenSettings,
            onSelectAccount: onSelectAccount,
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
        context.coordinator.update(
            workspaces: workspaces,
            currentWorkspace: currentWorkspace,
            connections: connections,
            accountSelection: accountSelection,
            onSelectWorkspace: onSelectWorkspace,
            onOpenSettings: onOpenSettings,
            onSelectAccount: onSelectAccount,
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
        let accountTitle = isLocalAccount
            ? L10n.localAccount
            : currentConnection?.displayName ?? L10n.dahliaNotSignedIn
        let workspaceTitle = currentWorkspace?.name ?? L10n.noWorkspaceSelected
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
            workspaceName: workspaceTitle,
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
            let icon = NSImage(systemSymbolName: isLocalAccount ? "person.2" : "icloud.slash", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular))
            button.setIcon(icon, animated: false)
        }
        button.toolTip = syncTitle
        button.setAccessibilityLabel("\(L10n.account), \(accountTitle); \(L10n.currentWorkspace), \(workspaceTitle); \(syncTitle ?? "")")
    }

    private var accountSelection: MainSidebarAccountSelection {
        MainSidebarAccountSelection(
            connectionID: currentConnectionID,
            isLocal: isLocalAccount,
            isLocalAvailable: isLocalAccountAvailable
        )
    }

    static func footerTitle(accountName: String, workspaceName: String, syncSummary: String? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: accountName,
            attributes: [.font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.labelColor]
        ))
        result.append(NSAttributedString(string: "\n"))
        result.append(workspaceLine(title: syncSummary.map { "\($0) · \(workspaceName)" } ?? workspaceName))
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = 6
        paragraphStyle.headIndent = 6
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func workspaceLine(title: String) -> NSAttributedString {
        let font = NSFont.preferredFont(forTextStyle: .footnote)
        return NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        )
    }
}
