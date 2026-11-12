import SwiftUI

struct MainSidebarAccountAppearanceMenuView: View {
    var navigation: MainSidebarAccountMenuNavigationState

    let onSelectAppearance: () -> Void

    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 2) {
            ForEach(AppAppearance.allCases.enumerated(), id: \.element.id) { index, appearance in
                MainSidebarAccountMenuRow(
                    title: appearance.displayName,
                    selectionState: appearance == settings.appAppearance,
                    isEnabled: appearance != settings.appAppearance,
                    isKeyboardHighlighted: navigation.activeMenu == .appearance && navigation.submenuSelection == index,
                    showsHelp: false,
                    onHoverStart: { navigation.selectSubmenu(index) },
                    action: { select(appearance) }
                )
            }
        }
    }

    private func select(_ appearance: AppAppearance) {
        settings.appAppearance = appearance
        onSelectAppearance()
    }
}
