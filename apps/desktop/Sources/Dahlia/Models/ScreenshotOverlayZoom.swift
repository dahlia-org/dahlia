import CoreGraphics

enum ScreenshotOverlayZoom {
    static let minimum: CGFloat = 0.5
    static let maximum: CGFloat = 2
    static let step: CGFloat = 0.25

    static func clamped(_ zoom: CGFloat) -> CGFloat {
        min(maximum, max(minimum, zoom))
    }
}
