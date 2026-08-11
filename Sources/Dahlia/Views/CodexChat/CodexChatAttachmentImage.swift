import SwiftUI

struct CodexChatAttachmentImage: View {
    let attachment: CodexChatImageAttachment
    let size: CGFloat

    @StateObject private var imageLoader = ScreenshotImageLoadModel()

    var body: some View {
        Group {
            switch imageLoader.state {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.small)
            case let .loaded(image):
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            case .failed:
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .task(id: attachment.id) {
            await imageLoader.load(
                screenshotID: attachment.id,
                data: attachment.data,
                maxPixelSize: Int(size * 2)
            )
        }
        .onDisappear(perform: imageLoader.unload)
    }

    private var accessibilityLabel: String {
        if case .failed = imageLoader.state {
            L10n.chatImageUnavailable
        } else {
            L10n.chatAttachedImage
        }
    }
}
