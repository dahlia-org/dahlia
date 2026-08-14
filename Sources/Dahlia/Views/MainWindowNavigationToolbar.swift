import SwiftUI

struct MainWindowNavigationToolbar: ToolbarContent {
    let isSidebarVisible: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let onToggleSidebar: () -> Void
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onToggleChat: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            HStack(spacing: 6) {
                Button(sidebarToggleLabel, systemImage: "sidebar.left", action: onToggleSidebar)
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .help(sidebarToggleLabel)
                Button(L10n.back, systemImage: "arrow.backward", action: onGoBack)
                    .disabled(!canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help(L10n.back)
                Button(L10n.forward, systemImage: "arrow.forward", action: onGoForward)
                    .disabled(!canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                    .help(L10n.forward)
                Button(L10n.chat, systemImage: "bubble.left.and.bubble.right", action: onToggleChat)
                    .help(L10n.chat)
                    .accessibilityLabel(L10n.chat)
            }
            .labelStyle(.iconOnly)
            .controlSize(.regular)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private var sidebarToggleLabel: String {
        isSidebarVisible ? L10n.hideSidebar : L10n.showSidebar
    }
}
