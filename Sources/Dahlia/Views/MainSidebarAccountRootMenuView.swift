import SwiftUI

struct MainSidebarAccountRootMenuView: View {
    @ObservedObject var navigation: MainSidebarAccountMenuNavigationState

    let onShowVaults: () -> Void
    let onShowLanguages: () -> Void
    let onDismissSubmenu: () -> Void
    let onOpenMCP: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            MainSidebarAccountMenuRow(
                title: L10n.vault,
                image: Image(systemName: "externaldrive"),
                showsDisclosure: true,
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == 0,
                onHoverStart: {
                    navigation.selectRoot(0)
                    onShowVaults()
                },
                action: onShowVaults
            )

            MainSidebarAccountMenuRow(
                title: L10n.language,
                image: Image(systemName: "globe"),
                showsDisclosure: true,
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == 1,
                onHoverStart: {
                    navigation.selectRoot(1)
                    onShowLanguages()
                },
                action: onShowLanguages
            )

            MainSidebarAccountMenuRow(
                title: L10n.mcpSettings,
                image: mcpImage,
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == 2,
                onHoverStart: {
                    navigation.selectRoot(2)
                    onDismissSubmenu()
                },
                action: onOpenMCP
            )
        }
    }

    private var mcpImage: Image {
        if let icon = Bundle.appModule.image(forResource: "MCPLogo") {
            Image(nsImage: icon).renderingMode(.template)
        } else {
            Image(systemName: "point.3.connected.trianglepath.dotted")
        }
    }
}
