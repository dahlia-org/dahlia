import SwiftUI

struct MainWorkspaceHeader: View {
    let isVisible: Bool
    let isSidebarVisible: Bool
    let isChatSidebarVisible: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let onToggleSidebar: () -> Void
    let onSearch: () -> Void
    let onGoBack: () -> Void
    let onGoForward: () -> Void
    let onToggleChat: () -> Void

    var body: some View {
        DahliaWindowHeader(reservesWindowControls: true, backgroundColor: .clear) {
            if isVisible {
                DahliaWindowHeaderIconButton(
                    label: sidebarToggleLabel,
                    systemImage: "sidebar.left",
                    action: onToggleSidebar
                )
                .keyboardShortcut("s", modifiers: [.command, .control])

                DahliaWindowHeaderIconButton(
                    label: L10n.search,
                    systemImage: "magnifyingglass",
                    action: onSearch
                )
                .keyboardShortcut("k", modifiers: .command)

                HStack(spacing: 2) {
                    DahliaWindowHeaderIconButton(
                        label: L10n.back,
                        systemImage: "arrow.backward",
                        action: onGoBack
                    )
                    .disabled(!canGoBack)
                    .keyboardShortcut("[", modifiers: .command)

                    DahliaWindowHeaderIconButton(
                        label: L10n.forward,
                        systemImage: "arrow.forward",
                        action: onGoForward
                    )
                    .disabled(!canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
                }
                .padding(.leading, 6)

                Spacer(minLength: 12)

                if !isChatSidebarVisible {
                    DahliaWindowHeaderIconButton(
                        label: L10n.showChat,
                        systemImage: "sidebar.right",
                        action: onToggleChat
                    )
                    .accessibilityValue(L10n.hidden)
                }
            }
        }
        .accessibilityHidden(!isVisible)
    }

    private var sidebarToggleLabel: String {
        isSidebarVisible ? L10n.hideSidebar : L10n.showSidebar
    }
}
