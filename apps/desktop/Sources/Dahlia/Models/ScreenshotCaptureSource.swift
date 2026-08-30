import CoreGraphics

enum ScreenshotCaptureSource: Hashable, Sendable {
    case none
    case entireDesktop
    case window(CGWindowID)

    var isSelected: Bool {
        self != .none
    }
}
