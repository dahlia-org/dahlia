import AppKit
import SwiftUI

struct MainSidebarAccountMenuButton: NSViewRepresentable {
    @State private var accountController = DahliaCloudAccountController.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let connections: [DahliaAccountConnection]
    let currentConnectionID: UUID?
    let isLocalAccount: Bool
    let onOpenSettings: (SettingsCategory?) -> Void
    let onSelectAccount: (DahliaAccountConnection?) -> Void
    var onAddAccount: () -> Void = {}
    let onAccountAction: () -> Void
    var unprocessedRecordingCount = 0
    let onShowUnprocessedRecordings: () -> Void

    func makeCoordinator() -> MainSidebarAccountMenuCoordinator {
        MainSidebarAccountMenuCoordinator(
            connections: connections,
            accountSelection: accountSelection,
            onOpenSettings: onOpenSettings,
            onSelectAccount: onSelectAccount,
            onAddAccount: onAddAccount,
            onAccountAction: onAccountAction,
            unprocessedRecordingCount: unprocessedRecordingCount,
            onShowUnprocessedRecordings: onShowUnprocessedRecordings
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
        // A long line (a workspace host) shrinks the button instead of pushing the help button out of the footer.
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            onAddAccount: onAddAccount,
            onAccountAction: onAccountAction,
            unprocessedRecordingCount: unprocessedRecordingCount,
            onShowUnprocessedRecordings: onShowUnprocessedRecordings
        )
        configure(button)
    }

    static func dismantleNSView(_: MainSidebarAccountButton, coordinator: MainSidebarAccountMenuCoordinator) {
        coordinator.dismissMenu()
    }

    private func configure(_ button: MainSidebarAccountButton) {
        _ = dynamicTypeSize
        let currentConnection = connections.first { $0.id == currentConnectionID }
        let accountTitle = isLocalAccount ? L10n.localAccount : currentConnection?.displayName ?? L10n.dahliaNotSignedIn
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
            syncSummary: progress?.state == .synced ? nil : syncTitle
        )
        let font = NSFont.dahliaBody
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
        button.setAccessibilityLabel("\(L10n.account), \(accountTitle); \(syncTitle ?? "")")
    }

    private var accountSelection: MainSidebarAccountSelection {
        MainSidebarAccountSelection(connectionID: currentConnectionID, isLocal: isLocalAccount)
    }

    static func footerTitle(accountName: String, syncSummary: String? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: accountName,
            attributes: [.font: NSFont.dahliaBody, .foregroundColor: NSColor.labelColor]
        ))
        if let syncSummary {
            result.append(NSAttributedString(
                string: "\n" + syncSummary,
                attributes: [.font: NSFont.dahliaSecondary, .foregroundColor: NSColor.secondaryLabelColor]
            ))
        }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = 6
        paragraphStyle.headIndent = 6
        // Each line ends in "…" when too long, rather than wrapping at a hyphen into a line the footer cannot show.
        paragraphStyle.lineBreakMode = .byTruncatingTail
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))
        return result
    }

}
