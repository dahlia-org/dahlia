import SwiftUI

enum ScreenshotOverlayLayout {
    static func fittedSize(imageSize: CGSize, availableSize: CGSize) -> CGSize {
        guard imageSize.width > 0,
              imageSize.height > 0,
              availableSize.width > 0,
              availableSize.height > 0 else { return .zero }

        let scale = min(
            availableSize.width / imageSize.width,
            availableSize.height / imageSize.height
        )
        return CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
    }
}

/// スクリーンショット拡大表示。手元の thumbnail を即時表示し、詳細画像へ段階更新する。
struct ScreenshotOverlayView: View {
    private static let imagePadding: CGFloat = 24

    /// Retina の全画面キャプチャを元解像度でレイヤー化すると、RenderBox の
    /// surface allocation が枯渇し得る。画面表示には十分なサイズへ制限する。
    private static let maximumDisplayPixelSize = 2400

    let screenshot: MeetingScreenshotRecord
    let previewImage: CGImage?
    let requestedAt: ContinuousClock.Instant
    let onDismiss: () -> Void

    @StateObject private var imageLoader = ScreenshotImageLoadModel()

    private var displayedImage: CGImage? {
        if case let .loaded(image) = imageLoader.state {
            return image
        }
        return previewImage
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            GeometryReader { proxy in
                Group {
                    if let displayedImage {
                        expandedImage(displayedImage, availableSize: proxy.size)
                    } else if case .failed = imageLoader.state {
                        monitoredContent {
                            Text(L10n.summaryImageUnavailable)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        monitoredContent {
                            ProgressView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            Button(L10n.close, systemImage: "xmark.circle.fill", action: onDismiss)
                .labelStyle(.iconOnly)
                .font(.title2)
                .foregroundStyle(.black)
                .padding(8)
                .background(.white, in: .circle)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .padding(16)
                .buttonStyle(.plain)
                .pointerStyle(.link)
        }
        .onAppear {
            ScreenshotImageDecodeWorker.recordOverlayPresented(
                requestedAt: requestedAt,
                hasPreview: previewImage != nil
            )
        }
        .task(id: screenshot.id) {
            await imageLoader.loadTransient(
                data: screenshot.imageData,
                maxPixelSize: Self.maximumDisplayPixelSize,
                requestedAt: requestedAt
            )
        }
        .onDisappear(perform: imageLoader.unload)
    }

    private func expandedImage(_ image: CGImage, availableSize: CGSize) -> some View {
        let contentSize = CGSize(
            width: max(0, availableSize.width - Self.imagePadding * 2),
            height: max(0, availableSize.height - Self.imagePadding * 2)
        )
        let imageSize = ScreenshotOverlayLayout.fittedSize(
            imageSize: CGSize(width: image.width, height: image.height),
            availableSize: contentSize
        )

        return Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: imageSize.width, height: imageSize.height)
            .clipShape(.rect(cornerRadius: 8))
            .background {
                ScreenshotOverlayInputMonitor(onDismiss: onDismiss)
            }
    }

    private func monitoredContent(@ViewBuilder content: () -> some View) -> some View {
        content()
            .background {
                ScreenshotOverlayInputMonitor(onDismiss: onDismiss)
            }
    }
}
