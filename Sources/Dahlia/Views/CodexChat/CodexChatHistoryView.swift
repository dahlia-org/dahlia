import SwiftUI

struct CodexChatHistoryView: View {
    let threads: [CodexChatThreadSummary]
    let hasMore: Bool
    let isLoading: Bool
    let onNewChat: () -> Void
    let onOpenThread: (CodexChatThreadSummary) -> Void
    let onLoadMore: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Button(L10n.newChat, systemImage: "square.and.pencil", action: onNewChat)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)

                if threads.isEmpty, !isLoading {
                    Text(L10n.noRecentChats)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }

                ForEach(threads) { thread in
                    Button {
                        onOpenThread(thread)
                    } label: {
                        CodexChatThreadRow(thread: thread)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                if hasMore {
                    Button(L10n.loadMore, action: onLoadMore)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .accessibilityLabel(L10n.chatModelLoading)
                }
            }
            .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
