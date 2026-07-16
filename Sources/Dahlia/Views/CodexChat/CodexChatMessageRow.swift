import SwiftUI

struct CodexChatMessageRow: View {
    let message: CodexChatMessage
    let meetingNamesByID: [UUID: String]

    var body: some View {
        let visibleText = message.role == .user ? userVisibleText : message.text
        let displayText = CodexChatMeetingReference.displayText(for: visibleText, namesByID: meetingNamesByID)
        let displayReasoning = CodexChatMeetingReference.displayText(
            for: message.reasoning,
            namesByID: meetingNamesByID
        )
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer(minLength: 72)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(displayText)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))

                    CodexChatCopyButton(text: displayText)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if !displayReasoning.isEmpty {
                        CodexChatReasoningView(
                            reasoning: displayReasoning,
                            isStreaming: message.isStreaming
                        )
                    }

                    if message.text.isEmpty, message.isStreaming {
                        ProgressView()
                            .controlSize(.small)
                    } else if !displayText.isEmpty {
                        if message.isStreaming {
                            Text(displayText)
                                .textSelection(.enabled)
                        } else {
                            CodexChatMarkdownView(markdown: displayText)
                        }
                    }

                    if !displayText.isEmpty, !message.isStreaming {
                        CodexChatCopyButton(text: displayText)
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
