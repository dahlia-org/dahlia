import SwiftUI

/// メインウィンドウに表示する設定画面。
struct SettingsView: View {
    @ObservedObject var captionViewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let appDatabase: AppDatabaseManager?
    var vaultManagementModel: VaultManagementModel
    @Bindable var mainWindowNavigation: MainWindowNavigation
    var onSelectVault: (VaultRecord) -> Void = { _ in }
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebarView(
                selection: $mainWindowNavigation.settingsCategory,
                onReturnToApp: mainWindowNavigation.dismissSettings
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            SettingsDetailView(
                selection: mainWindowNavigation.settingsCategory,
                captionViewModel: captionViewModel,
                sidebarViewModel: sidebarViewModel,
                appDatabase: appDatabase,
                vaultManagementModel: vaultManagementModel,
                onSelectVault: onSelectVault
            )
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            SidebarToggleToolbarItem(columnVisibility: $columnVisibility)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
