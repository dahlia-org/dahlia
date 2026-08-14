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
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)
            .background {
                SplitViewAutosaveView(widthDefaultsKey: "DahliaSettingsSidebar.width")
            }

            SettingsDetailView(
                selection: mainWindowNavigation.settingsCategory,
                captionViewModel: captionViewModel,
                sidebarViewModel: sidebarViewModel,
                appDatabase: appDatabase,
                vaultManagementModel: vaultManagementModel
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            // 空のツールバーを維持して、macOS のウィンドウ操作ボタンを表示する。
            ToolbarSpacer(.fixed, placement: .principal)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
