import SwiftUI

/// サブビューを水平に並べ、幅を超えたら自動折り返しするレイアウト。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat?

    private var effectiveRowSpacing: CGFloat { rowSpacing ?? spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let result = layout(in: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? result.maxX, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private struct LayoutResult {
        var positions: [CGPoint]
        var maxX: CGFloat
        var height: CGFloat
    }

    private func layout(in maxWidth: CGFloat, subviews: Subviews) -> LayoutResult {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + effectiveRowSpacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }

        return LayoutResult(positions: positions, maxX: maxX, height: y + rowHeight)
    }
}
