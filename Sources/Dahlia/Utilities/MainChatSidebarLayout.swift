import CoreGraphics

enum MainChatSidebarLayout {
    static let widthDefaultsKey = "DahliaChatSidebar.width"
    static let minimumWidth: CGFloat = 320
    static let defaultWidth: CGFloat = 380
    static let maximumWidth: CGFloat = 520
    static let toolbarHorizontalInset: CGFloat = 8
    static func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    static func toolbarContentWidth(for sidebarWidth: CGFloat) -> CGFloat {
        max(0, sidebarWidth - toolbarHorizontalInset * 2)
    }
}
