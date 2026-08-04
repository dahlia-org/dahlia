import SwiftUI

/// 設定画面（Cmd+, で表示）。
struct SettingsView: View {
    var captionViewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    var onSelectVault: (VaultRecord) -> Void = { _ in }

    @AppStorage(SettingsNavigation.selectedCategoryDefaultsKey)
    private var storedSelection = SettingsCategory.general.rawValue

    private var selectedCategory: SettingsCategory {
        SettingsNavigation.visibleSelection(rawValue: storedSelection)
    }

    private var selection: Binding<SettingsCategory> {
        Binding(
            get: { selectedCategory },
            set: { storedSelection = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                SettingsSidebarView(selection: selection)
                    .frame(width: 200)

                Divider()

                SettingsDetailView(
                    selection: selectedCategory,
                    captionViewModel: captionViewModel,
                    sidebarViewModel: sidebarViewModel,
                    onSelectVault: onSelectVault
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(selectedCategory.label)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            storedSelection = selectedCategory.rawValue
        }
    }
}
