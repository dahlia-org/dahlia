import SwiftUI

struct CodexChatMessageImageGrid: View {
    let attachments: [CodexChatImageAttachment]

    var body: some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            ForEach(attachments) { attachment in
                CodexChatAttachmentImage(
                    attachment: attachment,
                    size: CodexChatDesign.messageImageSize
                )
            }
        }
    }
}
