import SwiftUI

struct MainSidebarHelpMenuView: View {
    var navigation: MainSidebarAccountMenuNavigationState

    let onOpenMCP: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            MainSidebarAccountMenuRow(
                title: L10n.mcpSettings,
                image: mcpImage,
                isKeyboardHighlighted: navigation.rootSelection == 0,
                onHoverStart: { navigation.selectRoot(0) },
                action: onOpenMCP
            )

            MainSidebarAccountMenuRow(
                title: L10n.feedback,
                image: Image(systemName: "bubble.left"),
                isEnabled: false,
                action: {}
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
