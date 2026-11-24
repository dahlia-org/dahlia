import SwiftUI

/// The footer's settings menu: quick language and appearance changes, then the full Settings.
struct MainSidebarAccountRootMenuView: View {
    enum Item: Int, CaseIterable {
        case language
        case appearance
        case settings

        var title: String {
            switch self {
            case .language: L10n.language
            case .appearance: L10n.appearance
            case .settings: L10n.settings
            }
        }
    }

    var navigation: MainSidebarAccountMenuNavigationState

    let onShowAppearance: (CGFloat?) -> Void
    let onShowLanguages: (CGFloat?) -> Void
    let onDismissSubmenu: () -> Void
    let onOpenSettings: () -> Void

    @State private var pendingHoverTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 2) {
            MainSidebarAccountMenuRow(
                title: L10n.language,
                image: Image(systemName: "globe"),
                showsDisclosure: true,
                isKeyboardHighlighted: isHighlighted(.language),
                showsHelp: false,
                onHoverStartAtY: { minY in
                    hover(.language, opensSubmenu: true, action: { onShowLanguages(minY) })
                },
                onHoverEnd: cancelPendingHover,
                action: { activate(.language, action: { onShowLanguages(nil) }) }
            )

            MainSidebarAccountMenuRow(
                title: L10n.appearance,
                image: Image(systemName: "circle.lefthalf.filled"),
                showsDisclosure: true,
                isKeyboardHighlighted: isHighlighted(.appearance),
                showsHelp: false,
                onHoverStartAtY: { minY in
                    hover(.appearance, opensSubmenu: true, action: { onShowAppearance(minY) })
                },
                onHoverEnd: cancelPendingHover,
                action: { activate(.appearance, action: { onShowAppearance(nil) }) }
            )

            Divider()
                .padding(.vertical, 4)

            MainSidebarAccountMenuRow(
                title: L10n.settings,
                image: Image(systemName: "gearshape"),
                isKeyboardHighlighted: isHighlighted(.settings),
                showsHelp: false,
                onHoverStart: { hover(.settings, opensSubmenu: false, action: onDismissSubmenu) },
                onHoverEnd: cancelPendingHover,
                action: { activate(.settings, action: onOpenSettings) }
            )
        }
        .onDisappear(perform: cancelPendingHover)
    }

    private func isHighlighted(_ item: Item) -> Bool {
        navigation.activeMenu == .root && navigation.rootSelection == item.rawValue
    }

    private func hover(
        _ item: Item,
        opensSubmenu: Bool,
        action: @escaping () -> Void
    ) {
        cancelPendingHover()
        guard opensSubmenu else {
            action()
            navigation.selectRoot(item.rawValue)
            return
        }
        let applyHover = {
            navigation.selectRoot(item.rawValue)
            action()
        }
        guard navigation.activeMenu != .root else {
            applyHover()
            return
        }
        pendingHoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, navigation.activeMenu != .root else { return }
            pendingHoverTask = nil
            applyHover()
        }
    }

    private func activate(_ item: Item, action: () -> Void) {
        cancelPendingHover()
        navigation.selectRoot(item.rawValue)
        action()
    }

    private func cancelPendingHover() {
        pendingHoverTask?.cancel()
        pendingHoverTask = nil
    }
}
