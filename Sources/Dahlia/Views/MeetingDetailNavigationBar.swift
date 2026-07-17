import SwiftUI

/// Keeps meeting tabs and tab-specific commands in the meeting detail region at every window width.
struct MeetingDetailNavigationBar: View {
    @Binding var selection: DetailTab
    @ObservedObject var viewModel: CaptionViewModel

    var body: some View {
        DetailTabBar(selection: $selection, viewModel: viewModel)
    }
}
