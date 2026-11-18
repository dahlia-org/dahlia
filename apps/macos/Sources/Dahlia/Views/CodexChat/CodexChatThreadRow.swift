import SwiftUI

struct CodexChatThreadRow: View {
    let thread: CodexChatThreadSummary
    let meetingNamesByID: [UUID: String]
    let activity: CodexChatThreadActivity?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            if thread.parentThreadID != nil {
                Image(systemName: "arrow.turn.down.right")
                    .accessibilityLabel(L10n.chatChildThread)
            }
            Text(CodexChatMeetingReference.displayText(
                for: thread.title.nilIfBlank ?? L10n.newChat,
                namesByID: meetingNamesByID
            ))
            .lineLimit(1)
            Spacer(minLength: 12)
            CodexChatThreadStatusView(thread: thread, activity: activity)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .background(
            isHovering ? DahliaDesign.contentHighlightColor : .clear,
            in: RoundedRectangle(cornerRadius: DahliaDesign.Highlight.compactCornerRadius)
        )
        .onHover { isHovering = $0 }
        .padding(.bottom, 1)
        .accessibilityElement(children: .combine)
    }
}
