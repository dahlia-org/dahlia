import SwiftUI

struct MainSidebarBottomArea: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let recordingCoordinator: RecordingCoordinator
    var updateController: AppUpdateController
    let onSelectWorkspace: (WorkspaceRecord) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            MainSidebarFooterView(
                workspaces: sidebarViewModel.allWorkspaces,
                currentWorkspace: sidebarViewModel.currentWorkspace,
                updateController: updateController,
                onSelectWorkspace: onSelectWorkspace
            )
            .disabled(!viewModel.canSwitchWorkspace)
            .accessibilityHidden(viewModel.isListening)

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
