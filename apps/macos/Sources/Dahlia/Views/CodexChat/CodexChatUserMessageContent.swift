import SwiftUI

struct CodexChatUserMessageContent: View {
    let rawText: String
    let images: [CodexChatImageAttachment]
    let meetingNamesByID: [UUID: String]
    let meetingReferencesByID: [UUID: CodexChatMeetingReference]

    var body: some View {
        let content = CodexChatMeetingReference.previewContent(in: rawText)
        let displayInstruction = CodexChatMeetingReference.displayText(
            for: content.instruction,
            namesByID: meetingNamesByID
        )

        VStack(alignment: .leading, spacing: 6) {
            if !images.isEmpty {
                CodexChatMessageImageGrid(attachments: images)
            }

            if !content.referenceIDs.isEmpty {
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    ForEach(content.referenceIDs.indices, id: \.self) { index in
                        let id = content.referenceIDs[index]
                        CodexChatMeetingReferencePreviewBadge(
                            name: meetingNamesByID[id] ?? L10n.meetingUnavailable,
                            reference: meetingReferencesByID[id]
                        )
                    }
                }
            }

            if !displayInstruction.isEmpty {
                Text(displayInstruction)
                    .textSelection(.enabled)
            }
        }
    }
}
