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
            Text(thread.updatedAt, format: .relative(presentation: .named))
                .foregroundStyle(DahliaDesign.optionalTextColor)
                .lineLimit(1)
            if let activity {
                switch activity {
                case .queued:
                    Image(systemName: "clock").accessibilityHidden(true)
                case .running:
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .fixedSize()
                        .accessibilityHidden(true)
                case .waitingForUser:
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .frame(width: 16, height: 16)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }
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
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        switch activity {
        case .queued:
            L10n.chatRunStatus("queued")
        case .running:
            L10n.chatThreadRunning
        case .waitingForUser:
            L10n.chatThreadWaitingForUser
        case nil:
            ""
        }
    }
}
