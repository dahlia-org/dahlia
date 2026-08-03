import SwiftUI

struct CodexChatConversationView: View {
    let messages: [CodexChatMessage]
    let showsStandaloneThinking: Bool
    let meetingNamesByID: [UUID: String]
    let meetingReferencesByID: [UUID: CodexChatMeetingReference]

    @State private var scrollPosition = ScrollPosition()
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
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
            return ScrollMetrics(
                contentHeight: geometry.contentSize.height,
                isAtBottom: visibleBottom >= geometry.contentSize.height - 24
            )
        } action: { oldMetrics, newMetrics in
            let contentHeightChanged = oldMetrics.contentHeight != newMetrics.contentHeight
            if isFollowingLatest, contentHeightChanged {
                scrollToLatest()
            } else {
                isFollowingLatest = newMetrics.isAtBottom
            }
        }
        .onAppear(perform: scrollToLatest)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scrollToLatest() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    private struct ScrollMetrics: Equatable {
        let contentHeight: CGFloat
        let isAtBottom: Bool
    }
}
