import SwiftUI

struct CodexChatResizeHandles: View {
    @Binding var layout: CodexChatFloatingLayout
    let availableSize: CGSize

    var body: some View {
        let interactionSize = Self.interactionSize(for: layout.size)

        ZStack(alignment: .topLeading) {
            ForEach(CodexChatResizeEdge.allCases, id: \.self) { edge in
                let frame = Self.frame(for: edge, in: layout.size)
                CodexChatResizeHandle(layout: $layout, availableSize: availableSize, edge: edge)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .accessibilityHidden(edge != .top)
                    .accessibilityLabel(L10n.resize)
                    .accessibilityValue(accessibilityValue)
                    .accessibilityAdjustableAction { direction in
                        guard edge == .top else { return }
                        adjustSize(direction)
                    }
            }
        }
        .frame(width: interactionSize.width, height: interactionSize.height)
    }

    nonisolated static func frame(for edge: CodexChatResizeEdge, in size: CGSize) -> CGRect {
        let outset = CodexChatDesign.resizeHandleOutset
        let edgeThickness = CodexChatDesign.resizeEdgeThickness
        let cornerSize = CodexChatDesign.resizeCornerSize
        let cornerOffset = cornerSize / 2
        return switch edge {
        case .top:
            CGRect(
                x: outset + cornerOffset,
                y: 0,
                width: max(0, size.width - cornerSize),
                height: edgeThickness
            )
        case .left:
            CGRect(
                x: 0,
                y: outset + cornerOffset,
                width: edgeThickness,
                height: max(0, size.height - cornerOffset)
            )
        case .right:
            CGRect(
                x: outset + size.width,
                y: outset + cornerOffset,
                width: edgeThickness,
                height: max(0, size.height - cornerOffset)
            )
        case .topLeft:
            CGRect(x: outset - cornerOffset, y: outset - cornerOffset, width: cornerSize, height: cornerSize)
        case .topRight:
            CGRect(
                x: outset + size.width - cornerOffset,
                y: outset - cornerOffset,
                width: cornerSize,
                height: cornerSize
            )
        }
    }

    nonisolated static func interactionSize(for contentSize: CGSize) -> CGSize {
        let inset = CodexChatDesign.resizeHandleOutset * 2
        return CGSize(width: contentSize.width + inset, height: contentSize.height + inset)
    }

    nonisolated static func contentFrame(for contentSize: CGSize) -> CGRect {
        let outset = CodexChatDesign.resizeHandleOutset
        return CGRect(origin: CGPoint(x: outset, y: outset), size: contentSize)
    }

    private func adjustSize(_ direction: AccessibilityAdjustmentDirection) {
        let multiplier: CGFloat
        switch direction {
        case .increment:
            multiplier = 1
        case .decrement:
            multiplier = -1
        @unknown default:
            return
        }
        let step = CodexChatDesign.resizeAccessibilityStep * multiplier
        let edge: CodexChatResizeEdge = layout.dockSide == .left ? .topRight : .topLeft
        let horizontalTranslation = layout.dockSide == .left ? step : -step
        var resized = layout
        resized.resize(
            from: edge,
            translation: CGSize(width: horizontalTranslation, height: -step),
            availableSize: availableSize
        )
        layout = resized
    }

    private var accessibilityValue: String {
        "\(Int(layout.size.width.rounded())) × \(Int(layout.size.height.rounded()))"
    }
}
