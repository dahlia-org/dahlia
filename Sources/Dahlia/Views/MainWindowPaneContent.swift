import SwiftUI

/// 通常画面を保持したまま、同じ split view pane 内で設定内容へ切り替える。
struct MainWindowPaneContent<MainContent: View, SettingsContent: View>: View {
    enum SettingsBackground {
        case detail
        case sidebar
    }

    let isMainContentVisible: Bool
    let isShowingSettings: Bool
    var settingsBackground = SettingsBackground.detail
    @ViewBuilder let mainContent: MainContent
    @ViewBuilder let settingsContent: SettingsContent

    var body: some View {
        ZStack {
            mainContent
                .opacity(isMainContentVisible ? 1 : 0)
                .allowsHitTesting(isMainContentVisible && !isShowingSettings)
                .disabled(!isMainContentVisible || isShowingSettings)
                .accessibilityHidden(!isMainContentVisible || isShowingSettings)

            if isShowingSettings {
                settingsContent
                    .background {
                        settingsBackgroundView
                    }
            }
        }
    }

    @ViewBuilder
    private var settingsBackgroundView: some View {
        switch settingsBackground {
        case .detail:
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
        case .sidebar:
            Color(nsColor: .windowBackgroundColor)
                .overlay {
                    SidebarMaterialBackground()
                        .overlay {
                            Color(nsColor: .windowBackgroundColor)
                                .opacity(MainSidebarLayout.tintOpacity)
                        }
                }
                .ignoresSafeArea()
        }
    }
}
