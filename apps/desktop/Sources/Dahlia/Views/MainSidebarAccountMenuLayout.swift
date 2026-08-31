import CoreGraphics

enum MainSidebarAccountMenuLayout {
    static let menuWidth: CGFloat = 180
    static let rootMenuWidth: CGFloat = 280
    static let menuRowHeight: CGFloat = 30
    static let panelGap: CGFloat = 6
    static let screenInset: CGFloat = 6

    static func screenIndex(
        containing targetFrame: CGRect,
        screenFrames: [CGRect]
    ) -> Int? {
        let center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        return screenFrames.firstIndex { $0.contains(center) }
            ?? screenFrames.firstIndex { $0.intersects(targetFrame) }
    }

    static func mainMenuOrigin(
        panelSize: CGSize,
        buttonFrame: CGRect,
        screenFrame: CGRect
    ) -> CGPoint {
        let x = min(
            max(buttonFrame.minX, screenFrame.minX + screenInset),
            screenFrame.maxX - panelSize.width - screenInset
        )
        let preferredY = buttonFrame.maxY + panelGap
        let y = min(preferredY, screenFrame.maxY - panelSize.height - screenInset)
        return CGPoint(x: x, y: max(y, screenFrame.minY + screenInset))
    }

    static func submenuOrigin(
        panelSize: CGSize,
        mainPanelFrame: CGRect,
        screenFrame: CGRect,
        anchorY: CGFloat? = nil
    ) -> CGPoint {
        let rightX = mainPanelFrame.maxX + panelGap
        let leftX = mainPanelFrame.minX - panelSize.width - panelGap
        let preferredX = rightX + panelSize.width <= screenFrame.maxX - screenInset ? rightX : leftX
        let x = min(max(preferredX, screenFrame.minX + screenInset), screenFrame.maxX - panelSize.width - screenInset)
        let preferredY = (anchorY ?? mainPanelFrame.maxY) - panelSize.height
        let y = min(
            max(preferredY, screenFrame.minY + screenInset),
            screenFrame.maxY - panelSize.height - screenInset
        )
        return CGPoint(x: x, y: y)
    }

    static func submenuAnchorY(rowMinY: CGFloat, mainPanelFrame: CGRect) -> CGFloat {
        mainPanelFrame.maxY - rowMinY
    }

    static func helpOrigin(
        panelSize: CGSize,
        rowFrame: CGRect,
        mainPanelFrame: CGRect,
        screenFrame: CGRect
    ) -> CGPoint {
        let centeredX = mainPanelFrame.minX + rowFrame.midX - panelSize.width / 2
        let x = min(max(centeredX, screenFrame.minX + screenInset), screenFrame.maxX - panelSize.width - screenInset)
        let rowBottom = mainPanelFrame.maxY - rowFrame.maxY
        let preferredY = rowBottom - panelSize.height - panelGap
        let y = min(max(preferredY, screenFrame.minY + screenInset), screenFrame.maxY - panelSize.height - screenInset)
        return CGPoint(x: x, y: y)
    }
}
