import SwiftUI

struct CodexChatMessageRow: View {
    let message: CodexChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer(minLength: 72)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(userVisibleText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))

                    CodexChatCopyButton(text: userVisibleText)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if !message.reasoning.isEmpty {
                        CodexChatReasoningView(
                            reasoning: message.reasoning,
                            isStreaming: message.isStreaming
                        )
                    }

                    if message.text.isEmpty, message.isStreaming {
                        ProgressView()
                            .controlSize(.small)
                    } else if !message.text.isEmpty {
                        if message.isStreaming {
                            Text(message.text)
                                .textSelection(.enabled)
                        } else {
                            CodexChatMarkdownView(markdown: message.text)
                        }
                    }

                    if !message.text.isEmpty, !message.isStreaming {
                        CodexChatCopyButton(text: message.text)
                    }
                }
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var userVisibleText: String {
        CodexChatPromptCodec.visibleUserText(from: message.text)
    }
}
