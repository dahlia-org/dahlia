import CoreGraphics

struct CodexChatFloatingLayout: Equatable {
    static let defaultSize = CGSize(width: 520, height: 560)
    static let minimumSize = CGSize(width: 380, height: 320)
    static let margin: CGFloat = 16

    var size: CGSize
    var dockSide: CodexChatDockSide

    init(size: CGSize = Self.defaultSize, dockSide: CodexChatDockSide = .right) {
        self.size = size
        self.dockSide = dockSide
    }

    mutating func resize(translation: CGSize, availableSize: CGSize) {
        let widthDelta = dockSide == .right ? -translation.width : translation.width
        size = Self.clamped(
            CGSize(width: size.width + widthDelta, height: size.height - translation.height),
            availableSize: availableSize
        )
    }

    mutating func snap(horizontalCenter: CGFloat, availableWidth: CGFloat) {
        dockSide = horizontalCenter < availableWidth / 2 ? .left : .right
    }

    mutating func clamp(to availableSize: CGSize) {
        size = Self.clamped(size, availableSize: availableSize)
    }

    func origin(in availableSize: CGSize, dragTranslation: CGSize = .zero) -> CGPoint {
        let baseX = dockSide == .left
            ? Self.margin
            : max(Self.margin, availableSize.width - size.width - Self.margin)
        let maximumX = max(Self.margin, availableSize.width - size.width - Self.margin)
        return CGPoint(
            x: min(max(Self.margin, baseX + dragTranslation.width), maximumX),
            y: max(Self.margin, availableSize.height - size.height - Self.margin)
        )
    }

    private static func clamped(_ size: CGSize, availableSize: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minimumSize.width), max(minimumSize.width, availableSize.width - margin * 2)),
            height: min(max(size.height, minimumSize.height), max(minimumSize.height, availableSize.height - margin * 2))
        )
    }
}
