import SwiftUI

/// スクリーンショット拡大表示。手元の thumbnail を即時表示し、詳細画像へ段階更新する。
struct ScreenshotOverlayView: View {
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
            Button(action: onDismiss) {
                Color.black.opacity(0.7)
                    .ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .accessibilityLabel(L10n.close)

            if let displayedImage {
                Image(decorative: displayedImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 8))
                    .padding(24)
            } else if case .failed = imageLoader.state {
                Text(L10n.summaryImageUnavailable)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
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
}
