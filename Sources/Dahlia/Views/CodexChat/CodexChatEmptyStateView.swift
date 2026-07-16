import SwiftUI

struct CodexChatEmptyStateView: View {
    let recentThreads: [CodexChatThreadSummary]
    let meetingNamesByID: [UUID: String]
    let onOpenThread: (CodexChatThreadSummary) -> Void
    let onShowAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 40)

            if !recentThreads.isEmpty {
                Text(L10n.recentChats)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)

                ForEach(recentThreads) { thread in
                    Button {
                        onOpenThread(thread)
                    } label: {
                        CodexChatThreadRow(
                            thread: thread,
                            meetingNamesByID: meetingNamesByID
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Button(L10n.chatShowAll, action: onShowAll)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}
