import SwiftUI

struct CodexChatConversationView: View {
    private static let bottomID = "codex-chat-bottom"

    let messages: [CodexChatMessage]
    let showsStandaloneThinking: Bool
    let meetingNamesByID: [UUID: String]
    let meetingReferencesByID: [UUID: CodexChatMeetingReference]

    @Environment(\.isChatSidebarResizing) private var isChatSidebarResizing
    @State private var isFollowingLatest = true

    var body: some View {
        let items = CodexChatConversationItem.build(
            from: messages,
            showsStandaloneThinking: showsStandaloneThinking
        )
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(items) { item in
                        switch item {
                        case let .contextDivider(_, context):
                            CodexChatContextDivider(context: context)
                        case let .message(message, showsInlineActivity):
                            CodexChatMessageRow(
                                message: message,
                                showsInlineActivity: showsInlineActivity,
                                meetingNamesByID: meetingNamesByID,
                                meetingReferencesByID: meetingReferencesByID
                            )
                        case .thinking:
                            CodexChatThinkingIndicator()
                        }
                    }

                    Color.clear
                        .frame(height: 0)
                        .id(Self.bottomID)
                }
                .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onChange(of: messages.last) {
                scrollToLatest(with: proxy)
            }
            .onChange(of: showsStandaloneThinking) {
                scrollToLatest(with: proxy)
            }
            .onChange(of: isChatSidebarResizing) { wasResizing, isResizing in
                guard wasResizing, !isResizing else { return }
                scrollToLatest(with: proxy)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                return visibleBottom >= geometry.contentSize.height - 24
            } action: { _, isAtBottom in
                guard !isChatSidebarResizing else { return }
                isFollowingLatest = isAtBottom
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func scrollToLatest(with proxy: ScrollViewProxy) {
        guard isFollowingLatest, !isChatSidebarResizing else { return }
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }
}
