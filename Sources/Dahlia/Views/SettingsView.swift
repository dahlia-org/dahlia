import SwiftUI

/// メインウィンドウに表示する設定画面。
struct SettingsView: View {
    @ObservedObject var captionViewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let appDatabase: AppDatabaseManager?
    var vaultManagementModel: VaultManagementModel
    @Bindable var mainWindowNavigation: MainWindowNavigation

    var body: some View {
        HSplitView {
            SettingsSidebarView(
                selection: $mainWindowNavigation.settingsCategory,
                onReturnToApp: mainWindowNavigation.dismissSettings
            )
            .mainSidebarPane(
                width: mainWindowNavigation.sidebarWidth,
                onWidthChange: mainWindowNavigation.updateSidebarWidth
            )

            SettingsDetailView(
                selection: mainWindowNavigation.settingsCategory,
                captionViewModel: captionViewModel,
                sidebarViewModel: sidebarViewModel,
                appDatabase: appDatabase,
                vaultManagementModel: vaultManagementModel
            )
            .mainDetailPane()
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            // 空のツールバーを維持して、macOS のウィンドウ操作ボタンを表示する。
            ToolbarSpacer(.fixed, placement: .principal)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
