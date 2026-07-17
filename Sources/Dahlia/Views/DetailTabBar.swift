import SwiftUI

private extension DetailTab {
    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .notes: "1"
        case .screenshots: "2"
        case .transcript: "3"
        case .summary: "4"
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
        HStack(spacing: 4) {
            ForEach(DetailTab.allCases) { tab in
                Button(tab.label) { selection = tab }
                    .buttonStyle(.plain)
                    .font(.body)
                    .bold(tab == selection)
                    .foregroundStyle(tab == selection ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(.rect)
                    .overlay(alignment: .bottom) {
                        if tab == selection {
                            Capsule()
                                .fill(.primary)
                                .frame(height: 2)
                                .padding(.horizontal, 8)
                        }
                    }
                    .keyboardShortcut(tab.keyboardShortcut, modifiers: .command)
                    .help(tab.label)
                    .accessibilityAddTraits(tab == selection ? .isSelected : [])
            }
        }
        .disabled(isFolderOnly)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.meetingContent)
    }
}
