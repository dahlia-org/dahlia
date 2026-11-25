import SwiftUI

/// The steps of a finished run before its final answer: reasoning, tools, and steered input.
struct CodexChatWorkLogView: View {
    let steps: [CodexChatMessage]
    let duration: TimeInterval?
    let meetingNamesByID: [UUID: String]
    let meetingReferencesByID: [UUID: CodexChatMeetingReference]

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(L10n.chatWorkedFor(duration))
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .accessibilityHidden(true)
                    }
                    .font(.dahliaSecondary)
                    .foregroundStyle(DahliaDesign.secondaryTextColor)
                    .padding(.vertical, 2)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityHint(isExpanded ? L10n.collapse : L10n.expand)

                Divider()
            }

            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(steps) { step in
                        CodexChatMessageRow(
                            message: step,
                            showsFooter: false,
                            meetingNamesByID: meetingNamesByID,
                            meetingReferencesByID: meetingReferencesByID
                        )
                    }
                }
            }
        }
    }
}
