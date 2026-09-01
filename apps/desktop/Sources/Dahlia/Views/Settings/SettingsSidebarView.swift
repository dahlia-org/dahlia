import SwiftUI

struct SettingsSidebarView: View {
    @Binding var selection: SettingsCategory
    let vaults: [VaultRecord]
    let currentVault: VaultRecord?
    var updateController: AppUpdateController
    let onSelectVault: (VaultRecord) -> Void
    let onReturnToApp: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Button(action: onReturnToApp) {
                    MainSidebarNavigationLabel(
                        title: L10n.backToApp,
                        systemImage: "arrow.left"
                    )
                }
                .buttonStyle(.borderless)

                ForEach(SettingsGroup.allCases) { group in
                    Section(group.label) {
                        ForEach(group.categories) { category in
                            MainSidebarNavigationLabel(
                                title: category.label,
                                systemImage: category.systemImage,
                                isSelected: selection == category
                            )
                            .tag(category)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            MainSidebarFooterView(
                vaults: vaults,
                currentVault: currentVault,
                updateController: updateController,
                onSelectVault: onSelectVault
            )
        }
    }
}
