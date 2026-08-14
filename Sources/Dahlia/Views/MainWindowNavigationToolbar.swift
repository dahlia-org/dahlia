import SwiftUI

struct MainWindowNavigationToolbar: ToolbarContent {
    let isSidebarVisible: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let onToggleSidebar: () -> Void
    let onGoBack: () -> Void
    let onGoForward: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(sidebarToggleLabel, systemImage: "sidebar.left", action: onToggleSidebar)
                .labelStyle(.iconOnly)
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help(sidebarToggleLabel)
            Button(L10n.back, systemImage: "chevron.backward", action: onGoBack)
                .labelStyle(.iconOnly)
                .disabled(!canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help(L10n.back)
            Button(L10n.forward, systemImage: "chevron.forward", action: onGoForward)
                .labelStyle(.iconOnly)
                .disabled(!canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help(L10n.forward)
        }
    }

    private var sidebarToggleLabel: String {
        isSidebarVisible ? L10n.hideSidebar : L10n.showSidebar
    }
}
