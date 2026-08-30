import SwiftUI

enum MainSearchDesign {
    static let recentResultLimit = 6
    static let meetingPageSize = 50
    static let screenshotPageSize = 20
    static let projectResultLimit = 50
    static let panelWidth: CGFloat = 680
    static let panelMaximumHeight: CGFloat = 620
    static let panelCornerRadius: CGFloat = 20
    static let rowCornerRadius: CGFloat = 10
    static let screenshotGridSpacing: CGFloat = 8
    static let screenshotImageMaxPixelSize = 640
    static let screenshotHoverCardWidth: CGFloat = 360
    static let screenshotColumns = [
        GridItem(.adaptive(minimum: 144, maximum: 200), spacing: screenshotGridSpacing),
    ]
}
