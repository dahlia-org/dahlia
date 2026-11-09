import SwiftUI

private extension DetailTab {
    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .summary: "1"
        case .notes: "2"
        case .screenshots: "3"
        case .transcript: "4"
        case .conversationAnalytics: "5"
        }
    }
}

/// Navigation for the content that belongs to the selected meeting.
struct DetailTabBar: View {
    @Binding var selection: DetailTab
    @ObservedObject var viewModel: CaptionViewModel
    @ObservedObject var analyticsStore: MeetingConversationMetricsStore
    @ObservedObject private var settings = AppSettings.shared

    private var isFolderOnly: Bool {
        viewModel.currentMeetingId == nil && !viewModel.isListening && !viewModel.hasDraftMeeting
    }

    private var availableTabs: [DetailTab] {
        DetailTab.allCases.filter {
            $0 != .conversationAnalytics
                || (settings.isConversationAnalyticsBetaEnabled && analyticsStore.isTabAvailable)
        }
    }

    var body: some View {
        UnderlineTabBar(
            tabs: availableTabs,
            selection: $selection,
            label: \.label,
            keyboardShortcut: { $0.keyboardShortcut },
            isDisabled: isFolderOnly,
            accessibilityLabel: L10n.meetingContent
        )
    }
}
