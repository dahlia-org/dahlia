import AppKit
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

enum ScreenshotOverlayNavigation {
    /// 端を越える移動と、一覧から外れた現在 ID には nil を返す。巡回はしない。
    static func neighborID(in ids: [UUID], from currentID: UUID, offset: Int) -> UUID? {
        guard let index = ids.firstIndex(of: currentID) else { return nil }
        let neighborIndex = index + offset
        guard ids.indices.contains(neighborIndex) else { return nil }
        return ids[neighborIndex]
    }
}

/// 拡大表示に重ねる丸型ボタン。閉じる・コピー・前後送りで見た目を揃える。
private struct ScreenshotOverlayControlButton: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // クリック判定はラベルの形で決まる。contentShape をボタンの外に置くと
            // グリフの矩形しか反応せず、chevron のような細い記号は押しにくい。
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.title2)
                .foregroundStyle(.black)
                .padding(8)
                .background(.white, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .pointerStyle(.link)
        .help(title)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

/// スクリーンショット拡大表示。手元の thumbnail を即時表示し、詳細画像へ段階更新する。
struct ScreenshotOverlayView: View {
    private static let imagePadding: CGFloat = 24
    private static let navigationButtonWidth: CGFloat = 44
    private static let navigationSpacing: CGFloat = 12

    /// Retina の全画面キャプチャを元解像度でレイヤー化すると、RenderBox の
    /// surface allocation が枯渇し得る。画面表示には十分なサイズへ制限する。
    private static let maximumDisplayPixelSize = 2400

    let screenshot: MeetingScreenshotRecord
    let previewImage: CGImage?
    let requestedAt: ContinuousClock.Instant
    let canGoPrevious: Bool
    let canGoNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onDismiss: () -> Void

    @StateObject private var imageLoader = ScreenshotImageLoadModel()

    private var displayedImage: CGImage? {
        if case let .loaded(image) = imageLoader.state {
            return image
        }
        return previewImage
    }

    private var hasNavigation: Bool {
        canGoPrevious || canGoNext
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            GeometryReader { proxy in
                navigationChrome {
                    if let displayedImage {
                        expandedImage(displayedImage, availableSize: proxy.size)
                    } else if case .failed = imageLoader.state {
                        placeholder(availableSize: proxy.size) {
                            Text(L10n.summaryImageUnavailable)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        placeholder(availableSize: proxy.size) {
                            ProgressView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            ScreenshotOverlayControlButton(
                title: L10n.close,
                systemImage: "xmark.circle.fill",
                action: onDismiss
            )
            .padding(16)
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

    /// 送りボタンの列を差し引いた、画像が使える領域。
    private func contentSize(availableSize: CGSize) -> CGSize {
        let navigationInset = hasNavigation ? (Self.navigationButtonWidth + Self.navigationSpacing) * 2 : 0
        return CGSize(
            width: max(0, availableSize.width - Self.imagePadding * 2 - navigationInset),
            height: max(0, availableSize.height - Self.imagePadding * 2)
        )
    }

    /// 読み込み中と失敗時も画像と同じ幅を占め、送りボタンが左右に動かないようにする。
    /// 高さは広げない。上下の余白はそのまま「外側クリックで閉じる」領域として残る。
    private func placeholder(availableSize: CGSize, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(width: contentSize(availableSize: availableSize).width)
    }

    private func expandedImage(_ image: CGImage, availableSize: CGSize) -> some View {
        let imageSize = ScreenshotOverlayLayout.fittedSize(
            imageSize: CGSize(width: image.width, height: image.height),
            availableSize: contentSize(availableSize: availableSize)
        )

        return Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: imageSize.width, height: imageSize.height)
            .clipShape(.rect(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                ScreenshotOverlayControlButton(
                    title: L10n.copyImage,
                    systemImage: "doc.on.doc",
                    action: copyImageToGeneralPasteboard
                )
                .padding(12)
            }
            .contextMenu {
                Button(L10n.copyImage, systemImage: "doc.on.doc", action: copyImageToGeneralPasteboard)
            }
    }

    /// 送りボタンごと監視ビューの内側に置く。ボタンが bounds の外にあると、
    /// クリックが「オーバーレイ外クリック」と判定されて拡大表示が閉じてしまう。
    private func navigationChrome(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: Self.navigationSpacing) {
            if hasNavigation {
                navigationButton(
                    title: L10n.previousImage,
                    systemImage: "chevron.backward",
                    isEnabled: canGoPrevious,
                    action: onPrevious
                )
            }

            content()

            if hasNavigation {
                navigationButton(
                    title: L10n.nextImage,
                    systemImage: "chevron.forward",
                    isEnabled: canGoNext,
                    action: onNext
                )
            }
        }
        .background {
            ScreenshotOverlayInputMonitor(
                onDismiss: onDismiss,
                onPrevious: onPrevious,
                onNext: onNext
            )
        }
    }

    private func navigationButton(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        ScreenshotOverlayControlButton(
            title: title,
            systemImage: systemImage,
            isEnabled: isEnabled,
            action: action
        )
        .frame(width: Self.navigationButtonWidth)
    }

    private func copyImageToGeneralPasteboard() {
        Task {
            await copyImage(to: .general)
        }
    }

    func copyImage(to pasteboard: NSPasteboard = .general) async {
        await ScreenshotPasteboardWriter.write(screenshot, to: pasteboard)
    }
}
