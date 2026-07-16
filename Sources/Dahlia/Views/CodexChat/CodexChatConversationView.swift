import SwiftUI

struct CodexChatConversationView: View {
    let messages: [CodexChatMessage]
    let meetingNamesByID: [UUID: String]
    let meetingReferencesByID: [UUID: CodexChatMeetingReference]

    var body: some View {
        let items = CodexChatConversationItem.build(from: messages)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(items) { item in
                        switch item {
                        case let .contextDivider(_, context):
                            CodexChatContextDivider(context: context)
                        case let .message(message):
                            CodexChatMessageRow(
                                message: message,
                                meetingNamesByID: meetingNamesByID,
                                meetingReferencesByID: meetingReferencesByID
                            )
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
                .padding(.vertical, 12)
            }
            .onChange(of: messages.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: messages.last?.text) {
                scrollToBottom(proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let bottomID = "codex-chat-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }
}
