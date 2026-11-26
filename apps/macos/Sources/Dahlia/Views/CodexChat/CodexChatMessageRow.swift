import SwiftUI

struct CodexChatMessageRow: View {
    let message: CodexChatMessage
    var showsFooter = true
    let meetingNamesByID: [UUID: String]
    let meetingReferencesByID: [UUID: CodexChatMeetingReference]

    @State private var isHovered = false

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
                    if message.isSteer {
                        Label(L10n.chatSteer, systemImage: "arrow.turn.up.right")
                            .font(.dahliaSecondary)
                            .foregroundStyle(DahliaDesign.secondaryTextColor)
                            .padding(.trailing, 8)
                    }
                    CodexChatUserMessageContent(
                        rawText: visibleText,
                        images: message.images,
                        meetingNamesByID: meetingNamesByID,
                        meetingReferencesByID: meetingReferencesByID
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: CodexChatDesign.messageCornerRadius)
                    )

                    if showsFooter {
                        CodexChatMessageFooter(message: message, text: displayText, isHovered: isHovered)
                    }
                }
            } else if case let .notice(level) = message.role {
                CodexChatNoticeView(text: message.text, level: level)
            } else if case let .compaction(compaction) = message.role {
                CodexChatCompactionDivider(compaction: compaction)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if !displayReasoning.isEmpty {
                        CodexChatReasoningView(
                            reasoning: displayReasoning,
                            isStreaming: message.isStreaming
                        )
                    }

                    if !displayText.isEmpty {
                        CodexChatMarkdownView(
                            markdown: displayText,
                            isStreaming: message.isStreaming
                        )
                    }

                    if !message.toolActivities.isEmpty {
                        CodexChatToolUsesView(activities: message.toolActivities)
                    }

                    if showsFooter, message.hasResponseContent, !message.isStreaming {
                        CodexChatMessageFooter(message: message, text: displayText, isHovered: isHovered)
                    }
                }
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
    }

    private var userVisibleText: String {
        CodexChatPromptCodec.visibleUserText(from: message.text)
    }
}
