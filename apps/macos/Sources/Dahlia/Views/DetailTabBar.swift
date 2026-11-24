import SwiftUI

private extension DetailTab {
    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .summary: "1"
        case .notes: "2"
        case .screenshots: "3"
        case .transcript: "4"
        }
    }
}

/// Navigation for the content that belongs to the selected meeting.
struct DetailTabBar: View {
    @Binding var selection: DetailTab
    @ObservedObject var viewModel: CaptionViewModel

    private var isFolderOnly: Bool {
        viewModel.currentMeetingId == nil && !viewModel.isListening && !viewModel.hasDraftMeeting
    }

    var body: some View {
        UnderlineTabBar(
            tabs: DetailTab.allCases,
            selection: $selection,
            label: \.label,
            keyboardShortcut: { $0.keyboardShortcut },
            isDisabled: isFolderOnly,
            accessibilityLabel: L10n.meetingContent
        )
    }
}
