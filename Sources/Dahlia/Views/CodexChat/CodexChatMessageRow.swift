import SwiftUI

struct CodexChatMessageRow: View {
    let message: CodexChatMessage
    let meetingNamesByID: [UUID: String]
    let meetingReferencesByID: [UUID: CodexChatMeetingReference]

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
                    CodexChatUserMessageContent(
                        rawText: visibleText,
                        meetingNamesByID: meetingNamesByID,
                        meetingReferencesByID: meetingReferencesByID
                    )
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
                        CodexChatThinkingIndicator()
                    } else if !displayText.isEmpty {
                        CodexChatMarkdownView(
                            markdown: displayText,
                            isStreaming: message.isStreaming
                        )
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
