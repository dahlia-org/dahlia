import SwiftUI

enum MainSidebarTransition {
    static let duration = 0.25
    static let animation = Animation.smooth(duration: duration)
}

enum MainSidebarLayout {
    static let widthDefaultsKey = "DahliaSettingsSidebar.width"
    static let minimumWidth: CGFloat = 240
    static let defaultWidth: CGFloat = 275
    static let maximumWidth: CGFloat = 520
    static let tintOpacity = 0.7
    static let footerHeight: CGFloat = 46

    static func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }
}
