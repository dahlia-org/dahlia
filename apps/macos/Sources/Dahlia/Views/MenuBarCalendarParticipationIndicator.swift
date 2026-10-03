import AppKit
import SwiftUI

struct MenuBarCalendarParticipationIndicator: View {
    let isAttending: Bool

    var body: some View {
        Image(nsImage: isAttending ? Self.attendingIndicator : Self.notAttendingIndicator)
            .renderingMode(.template)
            .accessibilityHidden(true)
    }

    private static let attendingIndicator = makeIndicator(isAttending: true)
    private static let notAttendingIndicator = makeIndicator(isAttending: false)

    private static func makeIndicator(isAttending: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 6, height: 14), flipped: true) { _ in
            let width: CGFloat = isAttending ? 4 : 2
            NSColor.black.withAlphaComponent(isAttending ? 1 : 0.35).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: (6 - width) / 2, y: 1, width: width, height: 12),
                xRadius: width / 2,
                yRadius: width / 2
            ).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
