import SwiftUI

struct CodexChatConversationView: View {
    let messages: [CodexChatMessage]
    let meetingNamesByID: [UUID: String]
    let meetingReferencesByID: [UUID: CodexChatMeetingReference]

    var body: some View {
        let items = CodexChatConversationItem.build(from: messages)
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
            }
            .padding(.horizontal, CodexChatDesign.contentHorizontalPadding)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
