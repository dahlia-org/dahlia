import SwiftUI

/// メインウィンドウに表示する設定画面。
struct SettingsView: View {
    private static let contentTeardownDelay = Duration.milliseconds(100)

    @ObservedObject var captionViewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let appDatabase: AppDatabaseManager?
    var vaultManagementModel: VaultManagementModel
    @Bindable var mainWindowNavigation: MainWindowNavigation
    @State private var isContentMounted = false

    var body: some View {
        let isPresented = mainWindowNavigation.isShowingSettings
        let showsContent = isPresented || isContentMounted

        HSplitView {
            ZStack {
                if showsContent {
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
                if showsContent {
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
        .task(id: isPresented) {
            if isPresented {
                isContentMounted = true
                return
            }

            // Let the hidden overlay leave the compositor before dismantling its split view.
            try? await Task.sleep(for: Self.contentTeardownDelay)
            guard !Task.isCancelled else { return }
            isContentMounted = false
        }
    }
}
