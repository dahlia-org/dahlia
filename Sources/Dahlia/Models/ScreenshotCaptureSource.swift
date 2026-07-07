import CoreGraphics

enum ScreenshotCaptureSource: Hashable {
    case none
    case entireDesktop
    case window(CGWindowID)

    var isSelected: Bool {
        self != .none
    }
}
