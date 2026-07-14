import AppKit
import SwiftUI

struct MenuBarCalendarParticipationIndicator: View {
    let isAttending: Bool

    var body: some View {
        Image(nsImage: isAttending ? Self.solidIndicator : Self.dottedIndicator)
            .renderingMode(.template)
            .accessibilityHidden(true)
    }

    private static let solidIndicator = makeIndicator(isSolid: true)
    private static let dottedIndicator = makeIndicator(isSolid: false)

    private static func makeIndicator(isSolid: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 6, height: 14), flipped: true) { _ in
            NSColor.black.setFill()
            if isSolid {
                NSBezierPath(
                    roundedRect: NSRect(x: 2, y: 1, width: 2, height: 12),
                    xRadius: 1,
                    yRadius: 1
                ).fill()
            } else {
                for y in [1.5, 6, 10.5] {
                    NSBezierPath(ovalIn: NSRect(x: 2, y: y, width: 2, height: 2)).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
