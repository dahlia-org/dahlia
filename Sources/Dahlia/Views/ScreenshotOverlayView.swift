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

    static func displayedImage(
        previewImage: CGImage?,
        loadedImage: CGImage?,
        loadedScreenshotID: UUID?,
        screenshotID: UUID
    ) -> CGImage? {
        if loadedScreenshotID == screenshotID, let loadedImage { return loadedImage }
        return previewImage
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

/// 拡大表示に重ねる、ChatGPT スタイルの不透過な丸型ボタン。
private struct ScreenshotOverlayControlButton: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            // クリック判定はラベルの形で決まる。contentShape をボタンの外に置くと
            // グリフの矩形しか反応せず、chevron のような細い記号は押しにくい。
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.black)
                .frame(width: 44, height: 44)
                .background(
                    isHovered && isEnabled ? Color(white: 0.92) : .white,
                    in: .circle
                )
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .pointerStyle(.link)
        .help(title)
        .onHover { isHovered = $0 }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

/// スクリーンショット拡大表示。手元の thumbnail を即時表示し、詳細画像へ段階更新する。
struct ScreenshotOverlayView: View {
    private static let imagePadding: CGFloat = 24
    private static let navigationButtonWidth: CGFloat = 44
    private static let navigationSpacing: CGFloat = 12
    private static let toolbarSpacing: CGFloat = 8
    private static let toolbarReservedHeight: CGFloat = 72
    private static let zoomControlsReservedHeight: CGFloat = 60
    private static let informationPanelWidth: CGFloat = 320
    private static let informationPanelSpacing: CGFloat = 16
    private static let toolbarProtectedSize = CGSize(width: 232, height: 76)
    private static let zoomControlsProtectedSize = CGSize(width: 160, height: 60)
    private static let backdropColor = Color.black.opacity(0.82)

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
    var onDownload: () -> Void = {}
    let onDismiss: () -> Void
    var ocrStateProvider: @Sendable (UUID) async -> ScreenshotOCRState = { _ in .pending }

    @State private var imageLoader = ScreenshotImageLoadModel()
    @State private var ocrState: ScreenshotOCRState = .pending
    @State private var isShowingInformation = false
    @State private var zoom: CGFloat = 1
    @State private var loadedScreenshotID: UUID?

    private var displayedImage: CGImage? {
        let loadedImage: CGImage? = if case let .loaded(image) = imageLoader.state { image } else { nil }
        return ScreenshotOverlayLayout.displayedImage(
            previewImage: previewImage,
            loadedImage: loadedImage,
            loadedScreenshotID: loadedScreenshotID,
            screenshotID: screenshot.id
        )
    }

    private var hasNavigation: Bool {
        canGoPrevious || canGoNext
    }

    private var showsNavigationControls: Bool {
        if displayedImage != nil { return true }
        guard loadedScreenshotID == screenshot.id else { return false }
        if case .failed = imageLoader.state { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Self.backdropColor
                    .ignoresSafeArea()
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            GeometryReader { proxy in
                navigationChrome {
                    previewContent(availableSize: proxy.size)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            toolbar
                .padding(16)

            if displayedImage != nil {
                ScreenshotOverlayZoomControls(zoom: $zoom)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .onAppear {
            ScreenshotImageDecodeWorker.recordOverlayPresented(
                requestedAt: requestedAt,
                hasPreview: previewImage != nil
            )
        }
        .task(id: screenshot.id) {
            let screenshotID = screenshot.id
            loadedScreenshotID = nil
            zoom = 1
            await imageLoader.loadTransient(
                data: screenshot.imageData,
                maxPixelSize: Self.maximumDisplayPixelSize,
                requestedAt: requestedAt
            )
            guard !Task.isCancelled else { return }
            loadedScreenshotID = screenshotID
        }
        .task(id: screenshot.id) {
            ocrState = .pending
            repeat {
                ocrState = await ocrStateProvider(screenshot.id)
                if !ocrState.isTerminal { try? await Task.sleep(for: .seconds(2)) }
            } while !ocrState.isTerminal && !Task.isCancelled
        }
        .onDisappear(perform: imageLoader.unload)
    }

    /// 送りボタンの列を差し引いた、画像が使える領域。
    private func availableImageSize(in availableSize: CGSize) -> CGSize {
        let navigationInset = hasNavigation ? (Self.navigationButtonWidth + Self.navigationSpacing) * 2 : 0
        let informationInset = isShowingInformation
            ? Self.informationPanelWidth + Self.informationPanelSpacing
            : 0
        return CGSize(
            width: max(0, availableSize.width - Self.imagePadding * 2 - navigationInset - informationInset),
            height: max(
                0,
                availableSize.height - Self.imagePadding * 2
                    - Self.toolbarReservedHeight - Self.zoomControlsReservedHeight
            )
        )
    }

    private func previewContent(availableSize: CGSize) -> some View {
        let imageAreaSize = availableImageSize(in: availableSize)

        return HStack(spacing: Self.informationPanelSpacing) {
            if let displayedImage {
                expandedImage(displayedImage, availableSize: availableSize)
            } else if case .failed = imageLoader.state {
                placeholder(availableSize: availableSize) {
                    Text(L10n.summaryImageUnavailable)
                        .foregroundStyle(DahliaDesign.secondaryTextColor)
                }
            } else {
                placeholder(availableSize: availableSize) {
                    ProgressView()
                }
            }

            if isShowingInformation {
                ScreenshotOverlayInformationView(
                    screenshot: screenshot,
                    image: displayedImage,
                    ocrState: ocrState
                )
                .frame(
                    width: Self.informationPanelWidth,
                    height: imageAreaSize.height
                )
            }
        }
    }

    /// 読み込み中と失敗時も画像と同じ幅を占め、送りボタンが左右に動かないようにする。
    /// 高さは広げない。上下の余白はそのまま「外側クリックで閉じる」領域として残る。
    private func placeholder(availableSize: CGSize, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(width: availableImageSize(in: availableSize).width)
    }

    private func expandedImage(_ image: CGImage, availableSize: CGSize) -> some View {
        let imageAreaSize = availableImageSize(in: availableSize)
        let fittedImageSize = ScreenshotOverlayLayout.fittedSize(
            imageSize: CGSize(width: image.width, height: image.height),
            availableSize: imageAreaSize
        )
        let scaledImageSize = CGSize(
            width: fittedImageSize.width * zoom,
            height: fittedImageSize.height * zoom
        )
        let viewportSize = CGSize(
            width: min(scaledImageSize.width, imageAreaSize.width),
            height: min(scaledImageSize.height, imageAreaSize.height)
        )

        return Group {
            if zoom > 1 {
                ScrollView([.horizontal, .vertical]) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: scaledImageSize.width, height: scaledImageSize.height)
                }
                .defaultScrollAnchor(.center)
                .scrollClipDisabled(false)
                .scrollIndicators(.hidden)
            } else {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: scaledImageSize.width, height: scaledImageSize.height)
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .clipShape(.rect(cornerRadius: DahliaDesign.Media.cornerRadius))
        .contextMenu {
            Button(L10n.copyImage, systemImage: "doc.on.doc", action: copyImageToGeneralPasteboard)
            Button(L10n.download, systemImage: "arrow.down.to.line", action: onDownload)
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
                .opacity(showsNavigationControls ? 1 : 0)
                .allowsHitTesting(showsNavigationControls)
            }

            content()

            if hasNavigation {
                navigationButton(
                    title: L10n.nextImage,
                    systemImage: "chevron.forward",
                    isEnabled: canGoNext,
                    action: onNext
                )
                .opacity(showsNavigationControls ? 1 : 0)
                .allowsHitTesting(showsNavigationControls)
            }
        }
        .background {
            ScreenshotOverlayInputMonitor(
                onDismiss: onDismiss,
                onPrevious: onPrevious,
                onNext: onNext,
                topTrailingProtectedSize: Self.toolbarProtectedSize,
                bottomCenterProtectedSize: Self.zoomControlsProtectedSize
            )
        }
    }

    private var toolbar: some View {
        HStack(spacing: Self.toolbarSpacing) {
            ScreenshotOverlayControlButton(
                title: L10n.imageInformation,
                systemImage: "info.circle",
                action: { isShowingInformation.toggle() }
            )
            ScreenshotOverlayControlButton(
                title: L10n.copyImage,
                systemImage: "doc.on.doc",
                action: copyImageToGeneralPasteboard
            )
            ScreenshotOverlayControlButton(
                title: L10n.download,
                systemImage: "arrow.down.to.line",
                action: onDownload
            )
            ScreenshotOverlayControlButton(
                title: L10n.close,
                systemImage: "xmark",
                action: onDismiss
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
