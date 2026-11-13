import AppKit
import Foundation

enum CalendarEventTitle {
    static func attributed(_ title: String, for event: CalendarEvent) -> AttributedString {
        // Native menu labels preserve AppKit text attributes, not view-level styling.
        var text = AttributedString(title)
        if !event.isAttending {
            text.appKit.foregroundColor = NSColor.secondaryLabelColor
        }
        if event.isDeclined {
            text.appKit.strikethroughStyle = .single
        }
        return text
    }
}
