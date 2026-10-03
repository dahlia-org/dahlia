import CoreGraphics
import Foundation

struct ExpandedScreenshotPresentation {
    enum Scope {
        case allScreenshots
        case summary
    }

    let screenshot: MeetingScreenshotRecord
    let previewImage: CGImage?
    let requestedAt: ContinuousClock.Instant
    let scope: Scope
}
