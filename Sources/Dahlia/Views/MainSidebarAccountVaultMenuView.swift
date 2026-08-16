import SwiftUI

struct MainSidebarAccountVaultMenuView: View {
    var navigation: MainSidebarAccountMenuNavigationState

    let vaults: [VaultRecord]
    let currentVault: VaultRecord?
    let onSelectVault: (VaultRecord) -> Void
    let onManageVaults: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(vaults.enumerated(), id: \.element.id) { index, vault in
                            MainSidebarAccountMenuRow(
                                title: vault.name,
                                selectionState: vault.id == currentVault?.id,
                                isEnabled: vault.id != currentVault?.id,
                                isKeyboardHighlighted: navigation.activeMenu == .vaults && navigation.submenuSelection == index,
                                onHoverStart: { navigation.selectSubmenu(index) },
                                action: { onSelectVault(vault) }
                            )
                            .id(vault.id)
                        }
                    }
                }
                .frame(maxHeight: 320)
                .onChange(of: navigation.submenuSelection) { _, selection in
                    guard let selection, vaults.indices.contains(selection) else { return }
                    proxy.scrollTo(vaults[selection].id, anchor: .center)
                }
            }

            MainSidebarAccountMenuRow(
                title: L10n.manageVaults,
                image: Image(systemName: "gearshape"),
                isKeyboardHighlighted: navigation.activeMenu == .vaults && navigation.submenuSelection == vaults.count,
                onHoverStart: { navigation.selectSubmenu(vaults.count) },
                action: onManageVaults
            )
            .padding(.top, 6)
        }
    }
}
