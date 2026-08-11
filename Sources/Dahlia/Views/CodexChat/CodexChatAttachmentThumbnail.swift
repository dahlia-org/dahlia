import SwiftUI

struct CodexChatAttachmentThumbnail: View {
    let attachment: CodexChatImageAttachment
    let onRemove: (UUID) -> Void

    var body: some View {
        CodexChatAttachmentImage(
            attachment: attachment,
            size: CodexChatDesign.attachmentThumbnailSize
        )
        .overlay(alignment: .topTrailing) {
            Button(
                L10n.removeChatAttachedImage,
                systemImage: "xmark.circle.fill",
                action: { onRemove(attachment.id) }
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.65))
            .padding(3)
        }
    }
}
