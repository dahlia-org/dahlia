import CoreGraphics

enum MainSidebarAccountMenuLayout {
    static let menuWidth: CGFloat = 180
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
        screenFrame: CGRect
    ) -> CGPoint {
        let rightX = mainPanelFrame.maxX + panelGap
        let leftX = mainPanelFrame.minX - panelSize.width - panelGap
        let preferredX = rightX + panelSize.width <= screenFrame.maxX - screenInset ? rightX : leftX
        let x = min(max(preferredX, screenFrame.minX + screenInset), screenFrame.maxX - panelSize.width - screenInset)
        let preferredY = mainPanelFrame.maxY - panelSize.height
        let y = min(
            max(preferredY, screenFrame.minY + screenInset),
            screenFrame.maxY - panelSize.height - screenInset
        )
        return CGPoint(x: x, y: y)
    }
}
