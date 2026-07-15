import SwiftUI

struct CodexChatConversationView: View {
    let messages: [CodexChatMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(messages) { message in
                        CodexChatMessageRow(message: message)
                            .id(message.id)
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
