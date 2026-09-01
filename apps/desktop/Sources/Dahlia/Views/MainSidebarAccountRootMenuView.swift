import SwiftUI

struct MainSidebarAccountRootMenuView: View {
    var navigation: MainSidebarAccountMenuNavigationState

    let connections: [DahliaAccountConnection]
    let currentConnectionID: UUID?
    let isLocalAccount: Bool
    let isLocalAccountAvailable: Bool
    let vaults: [VaultRecord]
    let currentVault: VaultRecord?
    let onShowLanguages: (CGFloat?) -> Void
    let onDismissSubmenu: () -> Void
    let onShowAccountHelp: (String, CGRect) -> Void
    let onDismissAccountHelp: () -> Void
    let onOpenSettings: (SettingsCategory?) -> Void
    let onSelectAccount: (DahliaAccountConnection?) -> Void
    let onSelectVault: (VaultRecord) -> Void
    let onManageVaults: () -> Void
    let onAccountAction: () -> Void

    @State private var pendingHoverTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 2) {
            if let currentAccount = currentConnection?.account {
                Text(currentAccount.email ?? currentAccount.displayName)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)

            }

            ForEach(connections.enumerated(), id: \.element.id) { index, connection in
                MainSidebarAccountMenuRow(
                    title: connection.displayName,
                    subtitle: connection.isCloud ? L10n.dahliaCloud : L10n.dahliaServer,
                    image: Image(systemName: connection.isCloud ? "icloud" : "xserve"),
                    selectionState: connection.id == currentConnectionID,
                    isEnabled: connection.vaultCount > 0,
                    isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == index,
                    help: connection.origin,
                    showsHelp: false,
                    onHoverStart: { hover(index: index, submenu: nil, action: onDismissSubmenu) },
                    onHoverStartInFrame: { frame in
                        if !connection.isCloud {
                            onShowAccountHelp(connection.origin, frame)
                        }
                    },
                    onHoverEnd: {
                        cancelPendingHover()
                        onDismissAccountHelp()
                    },
                    action: { activate(index: index, action: { onSelectAccount(connection) }) }
                )
            }

            MainSidebarAccountMenuRow(
                title: L10n.localAccount,
                image: Image(systemName: "person.2"),
                selectionState: isLocalAccount,
                isEnabled: isLocalAccountAvailable,
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == connections.count,
                onHoverStart: { hover(index: connections.count, submenu: nil, action: onDismissSubmenu) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: connections.count, action: { onSelectAccount(nil) }) }
            )

            Divider()
                .padding(.vertical, 4)

            Text(L10n.vault)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .accessibilityAddTraits(.isHeader)

            ForEach(vaults.enumerated(), id: \.element.id) { index, vault in
                MainSidebarAccountMenuRow(
                    title: vault.name,
                    image: Image(systemName: "externaldrive"),
                    selectionState: vault.id == currentVault?.id,
                    isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == vaultOffset + index,
                    onHoverStart: { hover(index: vaultOffset + index, submenu: nil, action: onDismissSubmenu) },
                    onHoverEnd: cancelPendingHover,
                    action: { activate(index: vaultOffset + index, action: { onSelectVault(vault) }) }
                )
            }

            MainSidebarAccountMenuRow(
                title: L10n.manageVaults,
                image: Image(systemName: "gearshape"),
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == manageVaultsIndex,
                onHoverStart: { hover(index: manageVaultsIndex, submenu: nil, action: onDismissSubmenu) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: manageVaultsIndex, action: onManageVaults) }
            )

            Divider()
                .padding(.vertical, 4)

            MainSidebarAccountMenuRow(
                title: L10n.language,
                image: Image(systemName: "globe"),
                showsDisclosure: true,
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == menuOffset,
                onHoverStartAtY: { minY in hover(index: menuOffset, submenu: .languages, action: { onShowLanguages(minY) }) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: menuOffset, action: { onShowLanguages(nil) }) }
            )

            MainSidebarAccountMenuRow(
                title: L10n.settings,
                image: Image(systemName: "gearshape"),
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == menuOffset + 1,
                onHoverStart: { hover(index: menuOffset + 1, submenu: nil, action: onDismissSubmenu) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: menuOffset + 1, action: { onOpenSettings(nil) }) }
            )

            Divider()
                .padding(.vertical, 4)

            MainSidebarAccountMenuRow(
                title: currentConnection == nil ? L10n.dahliaSignIn : L10n.signOut,
                image: Image(systemName: currentConnection == nil ? "person" : "rectangle.portrait.and.arrow.right"),
                isKeyboardHighlighted: navigation.activeMenu == .root && navigation.rootSelection == menuOffset + 2,
                onHoverStart: { hover(index: menuOffset + 2, submenu: nil, action: onDismissSubmenu) },
                onHoverEnd: cancelPendingHover,
                action: { activate(index: menuOffset + 2, action: onAccountAction) }
            )
        }
        .onDisappear(perform: cancelPendingHover)
    }

    private var vaultOffset: Int { connections.count + 1 }
    private var manageVaultsIndex: Int { vaultOffset + vaults.count }
    private var menuOffset: Int { manageVaultsIndex + 1 }
    private var currentConnection: DahliaAccountConnection? {
        connections.first { $0.id == currentConnectionID }
    }

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
