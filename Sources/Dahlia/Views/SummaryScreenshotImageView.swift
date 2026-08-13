import AppKit
import SwiftUI

struct SummaryScreenshotImageView: View {
    let screenshot: MeetingScreenshotRecord
    let accessibilityLabel: String
    let onOpen: (UUID, CGImage) -> Void
    var onImageLoaded: (CGImage) -> Void = { _ in }
    @StateObject private var imageLoader = ScreenshotImageLoadModel()

    var body: some View {
        Group {
            if case let .loaded(image) = imageLoader.state {
                ZStack(alignment: .topTrailing) {
                    Button(action: { activate(image) }, label: {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFit()
                    })
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .accessibilityLabel(accessibilityLabel)
                    .help(accessibilityLabel)

                    Button(L10n.copyImage, systemImage: "doc.on.doc", action: copyImageToGeneralPasteboard)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .padding(6)
                        .background(.regularMaterial, in: .circle)
                        .padding(8)
                        .help(L10n.copyImage)
                }
                .contextMenu {
                    Button(L10n.copyImage, systemImage: "doc.on.doc", action: copyImageToGeneralPasteboard)
                }
            } else if case .failed = imageLoader.state {
                Text(L10n.summaryImageUnavailable)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
        .clipShape(.rect(cornerRadius: 6))
        .task(id: screenshot.id) {
            await imageLoader.load(
                screenshotID: screenshot.id,
                data: screenshot.imageData,
                maxPixelSize: 1200
            )
            if case let .loaded(image) = imageLoader.state {
                onImageLoaded(image)
            }
        }
    }

    func activate(_ image: CGImage) {
        onOpen(screenshot.id, image)
    }

    func copyImage(to pasteboard: NSPasteboard = .general) async {
        await ScreenshotPasteboardWriter.write(screenshot, to: pasteboard)
    }

    private func copyImageToGeneralPasteboard() {
        Task {
            await copyImage(to: .general)
        }
    }
}
