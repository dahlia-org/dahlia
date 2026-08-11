import CoreGraphics

enum OrganizationCanvasZoom {
    static let minimum: CGFloat = 0.5
    static let maximum: CGFloat = 2
    static let step: CGFloat = 0.1

    static func clamped(_ zoom: CGFloat) -> CGFloat {
        min(maximum, max(minimum, zoom))
    }

    static func applying(magnification: CGFloat, to zoom: CGFloat) -> CGFloat {
        clamped(zoom * magnification)
    }
}
