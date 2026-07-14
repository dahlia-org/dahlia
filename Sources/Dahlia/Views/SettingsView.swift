import SwiftUI

/// 設定画面（Cmd+, で表示）。
struct SettingsView: View {
    var sidebarViewModel: SidebarViewModel
    var onSelectVault: (VaultRecord) -> Void = { _ in }

    @AppStorage(SettingsNavigation.selectedCategoryDefaultsKey)
    private var selection: SettingsCategory = .general

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                SettingsSidebarView(selection: $selection)
                    .frame(width: 180)

                Divider()

                SettingsDetailView(
                    selection: selection,
                    sidebarViewModel: sidebarViewModel,
                    onSelectVault: onSelectVault
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(selection.label)
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}
