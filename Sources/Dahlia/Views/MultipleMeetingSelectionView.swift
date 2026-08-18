import SwiftUI

struct MultipleMeetingSelectionView: View {
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel
    @State private var isSummaryConfirmationPresented = false
    @State private var pendingMeetingDeletion: MeetingDeletionRequest?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checklist")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)

            Text(L10n.selectedCount(sidebarViewModel.selectedMeetingIds.count))
                .dahliaFont(.displayTitle, weight: .semibold)

            HStack(spacing: 10) {
                Button(
                    L10n.regenerateSummaries,
                    systemImage: "sparkles",
                    action: presentSummaryConfirmation
                )
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canRegenerateSummaries(meetingIds: sidebarViewModel.selectedMeetingIds))

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

                Button(role: .destructive) {
                    pendingMeetingDeletion = MeetingDeletionRequest(
                        meetingIds: sidebarViewModel.selectedMeetingIds,
                        meetingName: nil
                    )
                } label: {
                    Label(L10n.deleteCount(sidebarViewModel.selectedMeetingIds.count), systemImage: "trash")
                }

                Button(L10n.clear) {
                    sidebarViewModel.clearMeetingSelection()
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .sheet(isPresented: $isSummaryConfirmationPresented) {
            SummaryGenerationConfirmationView(
                title: L10n.regenerateSelectedSummariesConfirmationTitle,
                description: L10n.regenerateSelectedSummariesConfirmationDescription,
                actionTitle: L10n.regenerateSummaries,
                onGenerate: regenerateSummaries
            )
        }
        .meetingDeletionConfirmation(request: $pendingMeetingDeletion) { meetingIds in
            sidebarViewModel.deleteMeetings(ids: meetingIds)
        }
    }

    private func presentSummaryConfirmation() {
        isSummaryConfirmationPresented = true
    }

    private func regenerateSummaries(options: SummaryGenerationOptions) {
        viewModel.triggerManualSummaries(
            meetingIds: sidebarViewModel.selectedMeetingIds,
            dbQueue: sidebarViewModel.dbQueue,
            vaultURL: sidebarViewModel.currentVault?.url,
            options: options
        )
    }
}
