import SwiftUI

struct CodexChatThreadRow: View {
    let thread: CodexChatThreadSummary
    let meetingNamesByID: [UUID: String]

    var body: some View {
        HStack(spacing: 12) {
            Text(CodexChatMeetingReference.displayText(
                for: thread.title.nilIfBlank ?? L10n.newChat,
                namesByID: meetingNamesByID
            ))
            .lineLimit(1)
            Spacer(minLength: 12)
            Text(thread.updatedAt, format: .relative(presentation: .named))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}
