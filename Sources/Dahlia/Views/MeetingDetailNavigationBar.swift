import SwiftUI

/// Keeps meeting tabs and tab-specific commands in the meeting detail region at every window width.
struct MeetingDetailNavigationBar: View {
    @Binding var selection: DetailTab
    @ObservedObject var viewModel: CaptionViewModel

    private var showsSummaryActions: Bool {
        selection == .summary && (
            viewModel.canShareCurrentSummary
                || viewModel.lastSummaryURL != nil
                || viewModel.currentSummaryGoogleFileURL != nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailTabBar(selection: $selection, viewModel: viewModel)
            if showsSummaryActions {
                SummaryTabActions(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
