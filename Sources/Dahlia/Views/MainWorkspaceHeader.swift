import SwiftUI

struct MainWorkspaceHeader: View {
    let isVisible: Bool
    let isSidebarVisible: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let allowsWindowDragging: Bool
    let onToggleSidebar: () -> Void
    let onSearch: () -> Void
    let onGoBack: () -> Void
    let onGoForward: () -> Void

    var body: some View {
        DahliaWindowHeader(
            reservesWindowControls: true,
            allowsWindowDragging: allowsWindowDragging,
            backgroundColor: .clear
        ) {
            if isVisible {
                DahliaWindowHeaderIconButton(
                    label: sidebarToggleLabel,
                    systemImage: "sidebar.left",
                    helpShortcut: "⌘B",
                    action: onToggleSidebar
                )
                .keyboardShortcut("b", modifiers: .command)

                DahliaWindowHeaderIconButton(
                    label: L10n.search,
                    systemImage: "magnifyingglass",
                    helpShortcut: "⌘F",
                    action: onSearch
                )
                .keyboardShortcut("f", modifiers: .command)

                HStack(spacing: DahliaDesign.windowHeaderGroupSpacing) {
                    DahliaWindowHeaderIconButton(
                        label: L10n.back,
                        systemImage: "arrow.backward",
                        helpShortcut: "⌘[",
                        action: onGoBack
                    )
                    .disabled(!canGoBack)
                    .keyboardShortcut("[", modifiers: .command)

                    DahliaWindowHeaderIconButton(
                        label: L10n.forward,
                        systemImage: "arrow.forward",
                        helpShortcut: "⌘]",
                        action: onGoForward
                    )
                    .disabled(!canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                }
                Spacer(minLength: 12)
            }
        }
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
    }

    private var sidebarToggleLabel: String {
        isSidebarVisible ? L10n.hideSidebar : L10n.showSidebar
    }
}
