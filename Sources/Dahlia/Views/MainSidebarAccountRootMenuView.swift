import SwiftUI

struct MainSidebarAccountRootMenuView: View {
    var navigation: MainSidebarAccountMenuNavigationState

    let onShowVaults: () -> Void
    let onShowLanguages: () -> Void
    let onDismissSubmenu: () -> Void
    let onOpenMCP: () -> Void

    @State private var pendingHoverTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 2) {
            MainSidebarAccountMenuRow(
                title: L10n.vault,
                image: Image(systemName: "externaldrive"),
                showsDisclosure: true,
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == 0,
                onHoverStart: { hover(index: 0, submenu: .vaults, action: onShowVaults) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: 0, action: onShowVaults) }
            )

            MainSidebarAccountMenuRow(
                title: L10n.language,
                image: Image(systemName: "globe"),
                showsDisclosure: true,
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == 1,
                onHoverStart: { hover(index: 1, submenu: .languages, action: onShowLanguages) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: 1, action: onShowLanguages) }
            )

            MainSidebarAccountMenuRow(
                title: L10n.mcpSettings,
                image: mcpImage,
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == 2,
                onHoverStart: { hover(index: 2, submenu: nil, action: onDismissSubmenu) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: 2, action: onOpenMCP) }
            )
        }
        .onDisappear(perform: cancelPendingHover)
    }

    private func hover(
        index: Int,
        submenu: MainSidebarAccountMenuNavigationState.ActiveMenu?,
        action: @escaping () -> Void
    ) {
        cancelPendingHover()
        guard navigation.activeMenu != submenu else { return }
        let applyHover = {
            navigation.selectRoot(index)
            action()
        }
        guard navigation.activeMenu != .root else {
            applyHover()
            return
        }
        pendingHoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            pendingHoverTask = nil
            applyHover()
        }
    }

    private func activate(index: Int, action: () -> Void) {
        cancelPendingHover()
        navigation.selectRoot(index)
        action()
    }

    private func cancelPendingHover() {
        pendingHoverTask?.cancel()
        pendingHoverTask = nil
    }

    private var mcpImage: Image {
        if let icon = Bundle.appModule.image(forResource: "MCPLogo") {
            Image(nsImage: icon).renderingMode(.template)
        } else {
            Image(systemName: "point.3.connected.trianglepath.dotted")
        }
    }
}
