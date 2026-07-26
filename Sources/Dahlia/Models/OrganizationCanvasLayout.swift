import CoreGraphics
import Foundation

struct OrganizationCanvasLayoutInputNode: Equatable, Sendable {
    let id: UUID
    let depth: Int
}

struct OrganizationCanvasLayoutResult: Equatable, Sendable {
    let positions: [UUID: CGPoint]
    let size: CGSize
}

enum OrganizationCanvasLayout {
    static let nodeSize = CGSize(width: 200, height: 92)
    static let horizontalSpacing: CGFloat = 72
    static let verticalSpacing: CGFloat = 28
    static let canvasPadding: CGFloat = 48

    static func calculate(nodes: [OrganizationCanvasLayoutInputNode]) -> OrganizationCanvasLayoutResult {
        let grouped = Dictionary(grouping: nodes, by: \.depth)
        var positions: [UUID: CGPoint] = [:]
        var maximumColumnCount = 1
        for depth in grouped.keys.sorted() {
            let column = grouped[depth] ?? []
            maximumColumnCount = max(maximumColumnCount, column.count)
            for (index, node) in column.enumerated() {
                positions[node.id] = CGPoint(
                    x: canvasPadding + CGFloat(depth) * (nodeSize.width + horizontalSpacing),
                    y: canvasPadding + CGFloat(index) * (nodeSize.height + verticalSpacing)
                )
            }
        }
        let maximumDepth = nodes.map(\.depth).max() ?? 0
        return OrganizationCanvasLayoutResult(
            positions: positions,
            size: CGSize(
                width: canvasPadding * 2
                    + CGFloat(maximumDepth + 1) * nodeSize.width
                    + CGFloat(maximumDepth) * horizontalSpacing,
                height: canvasPadding * 2
                    + CGFloat(maximumColumnCount) * nodeSize.height
                    + CGFloat(maximumColumnCount - 1) * verticalSpacing
            )
        )
    }
}
