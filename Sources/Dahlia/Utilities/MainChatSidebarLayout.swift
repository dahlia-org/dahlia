import CoreGraphics

enum MainChatSidebarLayout {
    static let widthDefaultsKey = "DahliaChatSidebar.width"
    static let minimumWidth: CGFloat = 320
    static let defaultWidth: CGFloat = 380
    static let maximumWidth: CGFloat = 520
    static let minimumContentWidth: CGFloat = 500

    static func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    static func effectiveWidth(
        _ width: CGFloat,
        availableWidth: CGFloat,
        contentMinimumWidth: CGFloat = minimumContentWidth
    ) -> CGFloat {
        min(clampedWidth(width), max(minimumWidth, availableWidth - contentMinimumWidth), availableWidth)
    }
}
