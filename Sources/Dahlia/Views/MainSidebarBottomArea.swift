import SwiftUI

struct MainSidebarBottomArea: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator
    var updateController: AppUpdateController
    let onSelectVault: (VaultRecord) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MainSidebarFooterView(
            vaults: sidebarViewModel.allVaults,
            currentVault: sidebarViewModel.currentVault,
            updateController: updateController,
            onSelectVault: onSelectVault
        )
        .disabled(!viewModel.canSwitchVault)
        .accessibilityHidden(viewModel.isListening)
        .overlay(alignment: .bottom) {
            if viewModel.isListening {
                RecordingStatusBar(
                    viewModel: viewModel,
                    sidebarViewModel: sidebarViewModel,
                    recordingCoordinator: recordingCoordinator
                )
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.isListening)
    }
}
