import SwiftUI

struct MainSidebarAccountLanguageMenuView: View {
    var navigation: MainSidebarAccountMenuNavigationState

    let onSelectLanguage: () -> Void

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 2) {
            ForEach(AppLanguage.allCases.enumerated(), id: \.element.id) { index, language in
                MainSidebarAccountMenuRow(
                    title: language.displayName,
                    selectionState: language == settings.appLanguage,
                    isEnabled: language != settings.appLanguage,
                    isKeyboardHighlighted: navigation.activeMenu == .languages && navigation.submenuSelection == index,
                    onHoverStart: { navigation.selectSubmenu(index) },
                    action: { select(language) }
                )
            }
        }
    }

    private func select(_ language: AppLanguage) {
        settings.appLanguage = language
        onSelectLanguage()
    }
}
