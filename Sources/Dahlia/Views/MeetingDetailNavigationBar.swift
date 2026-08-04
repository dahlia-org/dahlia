import SwiftUI

private struct MeetingActionsMenu: View {
    @ObservedObject var viewModel: CaptionViewModel
    let onRename: () -> Void
    let onDelete: () -> Void

    private var canOpenSummary: Bool {
        viewModel.lastSummaryURL != nil || viewModel.currentSummaryGoogleFileURL != nil
    }

    var body: some View {
        Menu {
            Button(L10n.rename, systemImage: "pencil", action: onRename)

            if canOpenSummary {
                SummaryOpenMenu(viewModel: viewModel)
            }

            if viewModel.canRetranscribeBatchAudio {
                Button(
                    L10n.retranscribe,
                    systemImage: "arrow.clockwise",
                    action: viewModel.presentBatchRetranscriptionConfirmation
                )
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label(L10n.delete, systemImage: "trash")
            }
            .disabled(viewModel.currentMeetingId == nil)
        } label: {
            Label(L10n.actions, systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
    }
}

/// Keeps meeting tabs and meeting-wide actions in the detail navigation region at every window width.
struct MeetingDetailNavigationBar: View {
    @Binding var selection: DetailTab
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let onRename: () -> Void
    let onDelete: () -> Void

    private var showsActions: Bool {
        viewModel.hasDraftMeeting || viewModel.currentMeetingId != nil
    }

    var body: some View {
        HStack(spacing: 12) {
            DetailTabBar(selection: $selection, viewModel: viewModel)

            Spacer(minLength: 0)

            if showsActions {
                if selection == .summary {
                    HStack(spacing: 8) {
                        GenerateSummaryToolbarButton(
                            viewModel: viewModel,
                            sidebarViewModel: sidebarViewModel
                        )
                        ShareSummaryToolbarButton(viewModel: viewModel)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                MeetingActionsMenu(
                    viewModel: viewModel,
                    onRename: onRename,
                    onDelete: onDelete
                )
                .controlSize(.regular)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}
