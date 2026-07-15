import SwiftUI

struct CodexChatThreadRow: View {
    let thread: CodexChatThreadSummary

    var body: some View {
        HStack(spacing: 12) {
            Text(thread.title.nilIfBlank ?? L10n.newChat)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(thread.updatedAt, format: .relative(presentation: .named))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}
