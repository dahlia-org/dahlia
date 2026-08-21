import AppKit
import SwiftUI

@MainActor
final class LiveSubtitleOverlayService: ObservableObject {
    private let userDefaults: UserDefaults
    private var panel: NSPanel?
    private var hostingView: NSHostingView<LiveSubtitleOverlayView>?
    private var sizingView: NSHostingView<LiveSubtitleOverlaySizingView>?
    private var contentModel: ContentModel?
    private var panelMoveObserver: NSObjectProtocol?
    private var lastResolvedPanelSize: NSSize?
    private var pendingLayoutTask: Task<Void, Never>?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func update(payload: LiveSubtitleOverlayPayload?) {
        guard let payload else {
            hide()
            return
        }

        if let contentModel {
            guard contentModel.state.payload != payload else { return }
            contentModel.state = ContentModel.State(
                payload: payload,
                viewportHeight: viewportHeight(for: payload)
            )
            lastResolvedPanelSize = nil
        } else {
            let contentModel = ContentModel(state: ContentModel.State(
                payload: payload,
                viewportHeight: viewportHeight(for: payload)
            ))
            let overlayView = LiveSubtitleOverlayView(model: contentModel)
            let hostingView = NSHostingView(rootView: overlayView)
            hostingView.setFrameSize(resolvedPanelSize(for: hostingView.fittingSize))
            self.contentModel = contentModel
            self.hostingView = hostingView
            panel = makePanel(with: hostingView)
            panel?.alphaValue = 0
            panel?.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                self.panel?.animator().alphaValue = 1
            }
        }

        schedulePanelLayoutUpdate()
    }

    func hide() {
        pendingLayoutTask?.cancel()
        pendingLayoutTask = nil
        contentModel = nil
        hostingView = nil
        sizingView = nil
        lastResolvedPanelSize = nil

        guard let panel else { return }
        self.panel = nil
        removePanelMoveObserver()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                panel.close()
            }
        }
    }

    private func makePanel(with hostingView: NSHostingView<LiveSubtitleOverlayView>) -> NSPanel {
        let panelRect = panelFrame(for: hostingView.fittingSize)
        let panel = NSPanel(
            contentRect: panelRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.contentView = hostingView
        observePanelMoves(panel)
        return panel
    }

    private func schedulePanelLayoutUpdate() {
        pendingLayoutTask?.cancel()
        pendingLayoutTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.updatePanelLayout(animated: false)
            self?.pendingLayoutTask = nil
        }
    }

    private func viewportHeight(for payload: LiveSubtitleOverlayPayload) -> CGFloat {
        let rootView = LiveSubtitleOverlaySizingView(entries: payload.visibleEntries)
        let sizingView: NSHostingView<LiveSubtitleOverlaySizingView>
        if let existingSizingView = self.sizingView {
            existingSizingView.rootView = rootView
            sizingView = existingSizingView
        } else {
            let newSizingView = NSHostingView(rootView: rootView)
            self.sizingView = newSizingView
            sizingView = newSizingView
        }

        sizingView.layoutSubtreeIfNeeded()
        return max(sizingView.fittingSize.height, LiveSubtitleOverlayLayout.minimumViewportHeight).rounded()
    }

    private func updatePanelLayout(animated: Bool) {
        guard let panel, let hostingView else { return }

        hostingView.layoutSubtreeIfNeeded()
        let resolvedSize = resolvedPanelSize(for: hostingView.fittingSize)
        let nextFrame = panelFrame(for: resolvedSize, currentFrame: panel.frame)
        let cachedSize = lastResolvedPanelSize
        let sizeChanged = cachedSize.map { !sizesMatch($0, resolvedSize) } ?? false
        let frameChanged = !framesMatch(panel.frame, nextFrame)

        if cachedSize == nil {
            lastResolvedPanelSize = resolvedSize
            guard frameChanged else { return }
        } else {
            guard sizeChanged || frameChanged else { return }
            lastResolvedPanelSize = resolvedSize
        }

        let shouldDisplayImmediately = sizeChanged && nextFrame.isLargerThan(panel.frame)

        if animated {
            panel.animator().setFrame(nextFrame, display: true)
        } else {
            panel.setFrame(nextFrame, display: shouldDisplayImmediately)
        }
    }

    private func panelFrame(for size: NSSize, currentFrame: NSRect? = nil) -> NSRect {
        let resolvedSize = resolvedPanelSize(for: size)

        if let currentFrame {
            return frame(
                anchoredAtTopLeft: topLeft(of: currentFrame),
                size: resolvedSize,
                fallbackScreen: screen(containing: currentFrame) ?? NSScreen.main
            )
        }

        if let persistedTopLeft {
            return frame(
                anchoredAtTopLeft: persistedTopLeft,
                size: resolvedSize,
                fallbackScreen: screen(containing: persistedTopLeft) ?? NSScreen.main
            )
        }

        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: resolvedSize)
        }
        let visibleFrame = screen.visibleFrame
        let topLeft = CGPoint(
            x: visibleFrame.midX - resolvedSize.width / 2,
            y: visibleFrame.minY + 96 + resolvedSize.height
        )
        return frame(anchoredAtTopLeft: topLeft, size: resolvedSize, fallbackScreen: screen)
    }

    private var persistedTopLeft: CGPoint? {
        guard let pointString = userDefaults.string(forKey: LiveSubtitleOverlayLayout.anchorDefaultsKey) else {
            return nil
        }
        let point = NSPointFromString(pointString)
        guard point != .zero || pointString == NSStringFromPoint(.zero) else { return nil }
        return point
    }

    private func persistFrame(_ frame: NSRect) {
        userDefaults.set(NSStringFromPoint(topLeft(of: frame)), forKey: LiveSubtitleOverlayLayout.anchorDefaultsKey)
    }

    private func observePanelMoves(_ panel: NSPanel) {
        removePanelMoveObserver()
        panelMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel else { return }
                self.persistFrame(panel.frame)
            }
        }
    }

    private func removePanelMoveObserver() {
        guard let panelMoveObserver else { return }
        NotificationCenter.default.removeObserver(panelMoveObserver)
        self.panelMoveObserver = nil
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.intersects(frame) }
    }

    private func screen(containing origin: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.contains(origin) }
    }

    private func frame(anchoredAtTopLeft topLeft: CGPoint, size: NSSize, fallbackScreen: NSScreen?) -> NSRect {
        let clampedTopLeft = clampedTopLeft(
            preferredTopLeft: topLeft,
            size: size,
            fallbackScreen: fallbackScreen
        )
        let origin = CGPoint(
            x: clampedTopLeft.x.rounded(),
            y: (clampedTopLeft.y - size.height).rounded()
        )
        return NSRect(origin: origin, size: roundedSize(size))
    }

    private func topLeft(of frame: NSRect) -> CGPoint {
        CGPoint(x: frame.minX, y: frame.maxY)
    }

    private func resolvedPanelSize(for size: NSSize) -> NSSize {
        NSSize(
            width: LiveSubtitleOverlayLayout.fixedWidth,
            height: max(size.height, LiveSubtitleOverlayLayout.minimumHeight).rounded()
        )
    }

    private func roundedSize(_ size: NSSize) -> NSSize {
        NSSize(width: size.width.rounded(), height: size.height.rounded())
    }

    private func sizesMatch(_ lhs: NSSize, _ rhs: NSSize) -> Bool {
        roundedSize(lhs) == roundedSize(rhs)
    }

    private func framesMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        roundedFrame(lhs).equalTo(roundedFrame(rhs))
    }

    private func roundedFrame(_ frame: NSRect) -> NSRect {
        NSRect(
            x: frame.minX.rounded(),
            y: frame.minY.rounded(),
            width: frame.width.rounded(),
            height: frame.height.rounded()
        )
    }

    private func clampedTopLeft(preferredTopLeft: CGPoint, size: NSSize, fallbackScreen: NSScreen?) -> CGPoint {
        guard let visibleFrame = fallbackScreen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return preferredTopLeft
        }

        let minX = visibleFrame.minX
        let maxX = visibleFrame.maxX - size.width
        let minY = visibleFrame.minY + size.height
        let maxY = visibleFrame.maxY
        return CGPoint(
            x: min(max(preferredTopLeft.x, minX), maxX),
            y: min(max(preferredTopLeft.y, minY), maxY)
        )
    }
}

extension LiveSubtitleOverlayService: LiveSubtitlePresenting {}

private enum LiveSubtitleOverlayLayout {
    static let fixedWidth: CGFloat = 960
    static let minimumHeight: CGFloat = 72
    static let outerPadding: CGFloat = 12
    static let contentWidth = fixedWidth - outerPadding * 2
    static let minimumViewportHeight = minimumHeight - outerPadding * 2
    static let anchorDefaultsKey = "liveSubtitleOverlayTopLeftAnchor"
}

private extension NSRect {
    func isLargerThan(_ other: NSRect) -> Bool {
        width > other.width || height > other.height
    }
}

private final class ContentModel: ObservableObject {
    struct State: Equatable {
        let payload: LiveSubtitleOverlayPayload
        let viewportHeight: CGFloat
    }

    @Published var state: State

    init(state: State) {
        self.state = state
    }
}

private struct LiveSubtitleOverlayView: View {
    @ObservedObject var model: ContentModel
    @State private var scrollPosition = ScrollPosition(idType: UUID.self)
    @State private var isFollowingLatest = true

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.state.payload.entries) { entry in
                    LiveSubtitleEntryView(entry: entry)

                    if entry.id != model.state.payload.entries.last?.id {
                        Divider()
                            .overlay(Color.white.opacity(0.14))
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
            return ScrollMetrics(
                contentHeight: geometry.contentSize.height,
                containerHeight: geometry.containerSize.height,
                isAtBottom: visibleBottom >= geometry.contentSize.height - 24
            )
        } action: { oldMetrics, newMetrics in
            let layoutHeightChanged = oldMetrics.contentHeight != newMetrics.contentHeight ||
                oldMetrics.containerHeight != newMetrics.containerHeight
            if isFollowingLatest, layoutHeightChanged {
                scrollToLatest()
            } else {
                isFollowingLatest = newMetrics.isAtBottom
            }
        }
        .onChange(of: model.state) {
            guard isFollowingLatest else { return }
            scrollToLatest()
        }
        .frame(
            width: LiveSubtitleOverlayLayout.contentWidth,
            height: model.state.viewportHeight,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
        .padding(LiveSubtitleOverlayLayout.outerPadding)
        .dahliaAppearance()
    }

    private func scrollToLatest() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    private struct ScrollMetrics: Equatable {
        let contentHeight: CGFloat
        let containerHeight: CGFloat
        let isAtBottom: Bool
    }
}

private struct LiveSubtitleOverlaySizingView: View {
    let entries: [LiveSubtitleOverlayPayload.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(entries) { entry in
                LiveSubtitleEntryView(entry: entry)

                if entry.id != entries.last?.id {
                    Divider()
                        .overlay(Color.white.opacity(0.14))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: LiveSubtitleOverlayLayout.contentWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .dahliaAppearance()
    }
}

private struct LiveSubtitleEntryView: View {
    let entry: LiveSubtitleOverlayPayload.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.primaryText)
                .font(.body)
                .foregroundStyle(entry.isConfirmed ? .white : .white.opacity(0.7))
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            if let secondaryText = entry.secondaryText {
                Text(secondaryText)
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: .systemCyan))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
