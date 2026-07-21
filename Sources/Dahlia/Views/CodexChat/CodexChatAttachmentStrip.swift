import SwiftUI

struct CodexChatAttachmentStrip: View {
    let attachments: [CodexChatImageAttachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    CodexChatAttachmentThumbnail(
                        attachment: attachment,
                        onRemove: onRemove
                    )
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: CodexChatDesign.attachmentThumbnailSize)
        .scrollIndicators(.hidden)
        .accessibilityLabel(L10n.chatAttachedImages)
    }
}
