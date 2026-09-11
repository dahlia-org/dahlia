import SwiftUI

private struct SummaryGenerationConfirmationPresentationModifier: ViewModifier {
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: CaptionViewModel
    var sidebarViewModel: SidebarViewModel

    func body(content: Content) -> some View {
        ZStack {
            content
                .disabled(isPresented)
                .accessibilityHidden(isPresented)

            if isPresented {
                Button(action: dismiss) {
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityHidden(true)

                SummaryGenerationConfirmationView(
                    title: isBulk ? L10n.regenerateSelectedSummariesConfirmationTitle : L10n.summaryGenerationConfirmationTitle,
                    description: isBulk
                        ? L10n.regenerateSelectedSummariesConfirmationDescription
                        : L10n.summaryGenerationConfirmationDescription,
                    actionTitle: isBulk ? L10n.regenerateSummaries : L10n.generateSummary,
                    projects: isBulk ? nil : sidebarViewModel.flatProjects,
                    initialProjectId: isBulk ? nil : viewModel.currentProjectId,
                    initialDetailLevel: AppSettings.shared.summaryDetailLevel,
                    loadSourceAvailability: loadSourceAvailability,
                    onCancel: dismiss,
                    onGenerate: generate
                )
                .clipShape(.rect(cornerRadius: DahliaDesign.Card.regularCornerRadius))
                .shadow(color: .black.opacity(0.24), radius: 28, y: 12)
            }
        }
        .transition(.identity)
    }

    private var isBulk: Bool { sidebarViewModel.selectedMeetingIds.count > 1 }

    private var meetingIDs: Set<UUID> {
        if isBulk { return sidebarViewModel.selectedMeetingIds }
        return viewModel.currentMeetingId.map { [$0] } ?? []
    }

    private func loadSourceAvailability() async throws -> SummaryGenerationSourceAvailability {
        try await viewModel.summaryGenerationSourceAvailability(
            meetingIDs: meetingIDs,
            dbQueue: isBulk ? sidebarViewModel.dbQueue : nil
        )
    }

    private func generate(options: SummaryGenerationOptions, projectID: UUID?) -> String? {
        if isBulk {
            viewModel.triggerManualSummaries(
                meetingIds: meetingIDs,
                dbQueue: sidebarViewModel.dbQueue,
                vaultURL: sidebarViewModel.currentVault?.url,
                options: options
            )
            return nil
        }
        if let error = viewModel.assignCurrentMeetingProject(projectID) { return error }
        guard !viewModel.triggerManualSummary(options: options) else { return nil }
        return viewModel.isSummaryGenerating ? nil : L10n.summaryGenerationFailed
    }

    private func dismiss() {
        isPresented = false
    }
}

extension View {
    func summaryGenerationConfirmationPresentation(
        isPresented: Binding<Bool>,
        viewModel: CaptionViewModel,
        sidebarViewModel: SidebarViewModel
    ) -> some View {
        modifier(SummaryGenerationConfirmationPresentationModifier(
            isPresented: isPresented,
            viewModel: viewModel,
            sidebarViewModel: sidebarViewModel
        ))
    }
}
