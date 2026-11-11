import CoreGraphics

enum CodexChatAddPanelLayout {
    static let coordinateSpaceName = "CodexChatContent"
    private static let inset: CGFloat = 8
    private static let below: CGFloat = CodexChatDesign.controlSize + CodexChatDesign.floatingPanelSpacing

    static func width(windowBounds: CGRect) -> CGFloat {
        windowBounds.width > 0 ? min(280, windowBounds.width - inset * 2) : 280
    }

    static func maximumHeight(windowBounds: CGRect) -> CGFloat {
        guard windowBounds.height > 0 else { return 320 }
        let aboveSpace = -windowBounds.minY - CodexChatDesign.floatingPanelSpacing - inset
        let belowSpace = windowBounds.maxY - below - inset
        return max(80, min(320, max(aboveSpace, belowSpace)))
    }

    /// Bounds are in the add button's local coordinates. Prefer below and flip only when it cannot fit.
    static func offset(panelSize: CGSize, windowBounds: CGRect) -> CGSize {
        guard windowBounds.height > 0 else { return CGSize(width: 0, height: below) }
        let x = min(max(0, windowBounds.minX + inset), windowBounds.maxX - inset - panelSize.width)
        let y = below + panelSize.height <= windowBounds.maxY - inset
            ? below
            : -panelSize.height - CodexChatDesign.floatingPanelSpacing
        let constrainedY = min(max(y, windowBounds.minY + inset), windowBounds.maxY - inset - panelSize.height)
        return CGSize(width: x, height: constrainedY)
    }
}
