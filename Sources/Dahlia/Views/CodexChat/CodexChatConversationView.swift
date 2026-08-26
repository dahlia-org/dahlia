import SwiftUI

struct CodexChatConversationScrollState: Equatable {
    let isAtBottom: Bool

    func updatedFollowState(previous: Bool, isResizing: Bool) -> Bool {
        isResizing ? previous : isAtBottom
    }
}

struct CodexChatConversationView: View {
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
            }
            .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(isFollowingLatest ? .bottom : nil, for: .sizeChanges)
        .onScrollGeometryChange(for: CodexChatConversationScrollState.self) { geometry in
            let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
            return CodexChatConversationScrollState(
                isAtBottom: visibleBottom >= geometry.contentSize.height - 24
            )
        } action: { _, current in
            isFollowingLatest = current.updatedFollowState(
                previous: isFollowingLatest,
                isResizing: isChatSidebarResizing
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
