import SwiftUI

struct MultipleMeetingSelectionView: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    let onPresentSummaryGeneration: () -> Void
    @State private var pendingMeetingDeletion: MeetingDeletionRequest?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checklist")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(DahliaDesign.secondaryTextColor)

            Text(L10n.selectedCount(sidebarViewModel.selectedMeetingIds.count))
                .font(.title2)

            HStack(spacing: 10) {
                Button(
                    L10n.regenerateSummaries,
                    systemImage: "sparkles",
                    action: onPresentSummaryGeneration
                )
                .buttonStyle(.borderedProminent)
                .disabled(
                    !sidebarViewModel.canEditCurrentWorkspace
                        || !viewModel.canRegenerateSummaries(meetingIds: sidebarViewModel.selectedMeetingIds)
                )

                Menu {
                    Button(L10n.noProject) {
                        sidebarViewModel.moveMeetings(ids: sidebarViewModel.selectedMeetingIds, toProjectId: nil)
                    }

                    Divider()

                    ForEach(sidebarViewModel.allProjectItems) { project in
                        Button(project.projectName) {
                            sidebarViewModel.moveMeetings(
                                ids: sidebarViewModel.selectedMeetingIds,
                                toProjectId: project.projectId
                            )
                        }
                    }
                } label: {
                    Label(L10n.moveToProject, systemImage: "folder")
                }
                .disabled(!sidebarViewModel.canEditCurrentWorkspace)

                Button(role: .destructive) {
                    pendingMeetingDeletion = MeetingDeletionRequest(
                        meetingIds: sidebarViewModel.selectedMeetingIds,
                        meetingName: nil
                    )
                } label: {
                    Label(L10n.deleteCount(sidebarViewModel.selectedMeetingIds.count), systemImage: "trash")
                }
                .disabled(!sidebarViewModel.canEditCurrentWorkspace)

                Button(L10n.clear) {
                    sidebarViewModel.clearMeetingSelection()
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .meetingDeletionConfirmation(request: $pendingMeetingDeletion) { meetingIds in
            sidebarViewModel.deleteMeetings(ids: meetingIds)
        }
    }
}
