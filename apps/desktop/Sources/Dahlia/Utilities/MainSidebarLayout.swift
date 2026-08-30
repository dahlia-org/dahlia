import CoreGraphics

enum MainSidebarLayout {
    static let widthDefaultsKey = "DahliaSettingsSidebar.width"
    static let minimumWidth: CGFloat = 240
    static let defaultWidth: CGFloat = 275
    static let maximumWidth: CGFloat = 520
    static let minimumDetailWidth: CGFloat = 500
    static let minimumSplitWidth = minimumWidth + minimumDetailWidth
    static let tintOpacity = 0.7
    static let footerHeight: CGFloat = 46

    static func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    static func effectiveWidth(_ width: CGFloat, availableWidth: CGFloat) -> CGFloat {
        min(clampedWidth(width), max(minimumWidth, availableWidth - minimumDetailWidth), availableWidth)
    }
}
