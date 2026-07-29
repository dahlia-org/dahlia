import SwiftUI

/// Navigation for the content that belongs to the selected meeting.
struct DetailTabBar: View {
    @Binding var selection: DetailTab
    @ObservedObject var viewModel: CaptionViewModel
    let tabs: [DetailTab]

    private var isFolderOnly: Bool {
        viewModel.currentMeetingId == nil && !viewModel.isListening && !viewModel.hasDraftMeeting
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
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
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
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
