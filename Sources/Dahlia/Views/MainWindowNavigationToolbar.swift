import SwiftUI

struct SidebarToggleToolbarItem: ToolbarContent {
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            } label: {
                Label(
                    columnVisibility == .detailOnly ? L10n.showSidebar : L10n.hideSidebar,
                    systemImage: "sidebar.left"
                )
            }
            .labelStyle(.iconOnly)
            .help(columnVisibility == .detailOnly ? L10n.showSidebar : L10n.hideSidebar)
        }
    }
}

struct MainWindowNavigationToolbar: ToolbarContent {
    let canGoBack: Bool
    let canGoForward: Bool
    let onGoBack: () -> Void
    let onGoForward: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
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
}
