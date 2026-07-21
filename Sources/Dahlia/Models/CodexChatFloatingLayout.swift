import CoreGraphics

struct CodexChatFloatingLayout: Equatable {
    static let defaultSize = CGSize(width: 520, height: 560)
    static let minimumSize = CGSize(width: 380, height: 320)
    static let margin: CGFloat = 16

    var size: CGSize
    var dockSide: CodexChatDockSide
    private var undockedOriginX: CGFloat?

    init(size: CGSize = Self.defaultSize, dockSide: CodexChatDockSide = .right) {
        self.size = size
        self.dockSide = dockSide
    }

    mutating func resize(
        from edge: CodexChatResizeEdge,
        translation: CGSize,
        availableSize: CGSize
    ) {
        let wasDocked = undockedOriginX == nil
        let initialFrame = frame(in: availableSize)
        var left = initialFrame.minX
        var right = initialFrame.maxX
        var top = initialFrame.minY

        if edge.resizesLeft {
            left = min(
                max(Self.margin, initialFrame.minX + translation.width),
                initialFrame.maxX - Self.minimumSize.width
            )
        } else if edge.resizesRight {
            right = min(
                max(initialFrame.minX + Self.minimumSize.width, initialFrame.maxX + translation.width),
                max(initialFrame.minX + Self.minimumSize.width, availableSize.width - Self.margin)
            )
        }

        if edge.resizesTop {
            top = min(
                max(Self.margin, initialFrame.minY + translation.height),
                initialFrame.maxY - Self.minimumSize.height
            )
        }

        size = CGSize(width: right - left, height: initialFrame.maxY - top)
        if edge.resizesLeft || edge.resizesRight {
            let preservesDock = wasDocked && (
                dockSide == .left && edge.resizesRight ||
                    dockSide == .right && edge.resizesLeft
            )
            undockedOriginX = preservesDock ? nil : left
        }
    }

    mutating func snap(horizontalCenter: CGFloat, availableWidth: CGFloat) {
        dockSide = horizontalCenter < availableWidth / 2 ? .left : .right
        undockedOriginX = nil
    }

    mutating func clamp(to availableSize: CGSize) {
        size = Self.clamped(size, availableSize: availableSize)
        if let undockedOriginX {
            let maximumX = max(Self.margin, availableSize.width - size.width - Self.margin)
            self.undockedOriginX = min(max(Self.margin, undockedOriginX), maximumX)
        }
    }

    func origin(in availableSize: CGSize, dragTranslation: CGSize = .zero) -> CGPoint {
        let baseX = undockedOriginX ?? dockedOriginX(in: availableSize)
        let maximumX = max(Self.margin, availableSize.width - size.width - Self.margin)
        return CGPoint(
            x: min(max(Self.margin, baseX + dragTranslation.width), maximumX),
            y: max(Self.margin, availableSize.height - size.height - Self.margin)
        )
    }

    func frame(in availableSize: CGSize) -> CGRect {
        CGRect(origin: origin(in: availableSize), size: size)
    }

    private func dockedOriginX(in availableSize: CGSize) -> CGFloat {
        dockSide == .left
            ? Self.margin
            : max(Self.margin, availableSize.width - size.width - Self.margin)
    }

    private static func clamped(_ size: CGSize, availableSize: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minimumSize.width), max(minimumSize.width, availableSize.width - margin * 2)),
            height: min(max(size.height, minimumSize.height), max(minimumSize.height, availableSize.height - margin * 2))
        )
    }
}
