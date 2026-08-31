import SwiftUI

struct MainSidebarAccountRootMenuView: View {
    var navigation: MainSidebarAccountMenuNavigationState

    let account: DahliaCloudAccount?
    let accountOrigin: String?
    let isCloudAccount: Bool?
    let onShowVaults: (CGFloat?) -> Void
    let onShowLanguages: (CGFloat?) -> Void
    let onDismissSubmenu: () -> Void
    let onShowAccountHelp: (String, CGRect) -> Void
    let onDismissAccountHelp: () -> Void
    let onOpenSettings: (SettingsCategory?) -> Void
    let onAccountAction: () -> Void

    @State private var pendingHoverTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 2) {
            if let account {
                Text(account.email ?? account.displayName)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)

                MainSidebarAccountMenuRow(
                    title: accountServiceName,
                    image: Image(systemName: accountSystemImage),
                    isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == 0,
                    help: accountOrigin,
                    showsHelp: false,
                    onHoverStart: { hover(index: 0, submenu: nil, action: onDismissSubmenu) },
                    onHoverStartInFrame: { frame in
                        if let accountOrigin, isCloudAccount != true {
                            onShowAccountHelp(accountOrigin, frame)
                        }
                    },
                    onHoverEnd: {
                        cancelPendingHover()
                        onDismissAccountHelp()
                    },
                    action: { activate(index: 0, action: { onOpenSettings(.general) }) }
                )

                Divider()
                    .padding(.vertical, 4)
            }

            MainSidebarAccountMenuRow(
                title: L10n.vault,
                image: Image(systemName: "externaldrive"),
                showsDisclosure: true,
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == menuOffset,
                onHoverStartAtY: { minY in hover(index: menuOffset, submenu: .vaults, action: { onShowVaults(minY) }) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: menuOffset, action: { onShowVaults(nil) }) }
            )

            MainSidebarAccountMenuRow(
                title: L10n.language,
                image: Image(systemName: "globe"),
                showsDisclosure: true,
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == menuOffset + 1,
                onHoverStartAtY: { minY in hover(index: menuOffset + 1, submenu: .languages, action: { onShowLanguages(minY) }) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: menuOffset + 1, action: { onShowLanguages(nil) }) }
            )

            MainSidebarAccountMenuRow(
                title: L10n.settings,
                image: Image(systemName: "gearshape"),
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == menuOffset + 2,
                onHoverStart: { hover(index: menuOffset + 2, submenu: nil, action: onDismissSubmenu) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: menuOffset + 2, action: { onOpenSettings(nil) }) }
            )

            Divider()
                .padding(.vertical, 4)

            MainSidebarAccountMenuRow(
                title: account == nil ? L10n.dahliaSignIn : L10n.signOut,
                image: Image(systemName: account == nil ? "person" : "rectangle.portrait.and.arrow.right"),
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == menuOffset + 3,
                onHoverStart: { hover(index: menuOffset + 3, submenu: nil, action: onDismissSubmenu) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: menuOffset + 3, action: onAccountAction) }
            )
        }
        .onDisappear(perform: cancelPendingHover)
    }

    private var menuOffset: Int { account == nil ? 0 : 1 }
    private var accountServiceName: String { isCloudAccount == true ? L10n.dahliaCloud : L10n.dahliaServer }
    private var accountSystemImage: String { isCloudAccount == true ? "icloud" : "xserve" }

    private func hover(
        index: Int,
        submenu: MainSidebarAccountMenuNavigationState.ActiveMenu?,
        action: @escaping () -> Void
    ) {
        cancelPendingHover()
        guard let submenu else {
            action()
            navigation.selectRoot(index)
            return
        }
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
}
