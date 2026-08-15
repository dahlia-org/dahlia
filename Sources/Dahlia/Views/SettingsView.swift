import SwiftUI

/// メインウィンドウに表示する設定画面。
struct SettingsView: View {
    @ObservedObject var captionViewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let appDatabase: AppDatabaseManager?
    var vaultManagementModel: VaultManagementModel
    @Bindable var mainWindowNavigation: MainWindowNavigation

    var body: some View {
        let isPresented = mainWindowNavigation.isShowingSettings

        HSplitView {
            ZStack {
                if isPresented {
                    SettingsSidebarView(
                        selection: $mainWindowNavigation.settingsCategory,
                        onReturnToApp: mainWindowNavigation.dismissSettings
                    )
                }
            }
            .mainSidebarPane(
                width: mainWindowNavigation.sidebarWidth,
                onWidthChange: mainWindowNavigation.updateSidebarWidth
            )

            ZStack {
                if isPresented {
                    SettingsDetailView(
                        selection: mainWindowNavigation.settingsCategory,
                        captionViewModel: captionViewModel,
                        sidebarViewModel: sidebarViewModel,
                        appDatabase: appDatabase,
                        vaultManagementModel: vaultManagementModel
                    )
                }
            }
            .mainDetailPane()
        }
    }
}
