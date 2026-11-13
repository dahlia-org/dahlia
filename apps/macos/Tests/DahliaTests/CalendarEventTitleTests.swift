import AppKit
import Foundation
import SwiftUI
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CalendarEventTitleTests {
        @Test
        func resolvedMeetingTitleTrimsWhitespaceAndFallsBackForBlankTitles() {
            #expect(calendarEvent(title: "  Planning  ").resolvedMeetingTitle == "Planning")
            #expect(calendarEvent(title: " \n ").resolvedMeetingTitle == L10n.newMeeting)
        }

        @Test(arguments: [false, true], [false, true])
        func titlesReflectParticipation(isAttending: Bool, isDeclined: Bool) {
            let event = calendarEvent(title: "Planning", isDeclined: isDeclined, isAttending: isAttending)
            let title = CalendarEventTitle.attributed("Planning", for: event)
            let nativeTitle = NSAttributedString(title)
            let attributes = nativeTitle.attributes(at: 0, effectiveRange: nil)

            #expect(nativeTitle.string == "Planning")
            #expect((attributes[.foregroundColor] as? NSColor) == (event.isAttending ? nil : .secondaryLabelColor))
            #expect((attributes[.strikethroughStyle] as? Int) == (isDeclined ? NSUnderlineStyle.single.rawValue : nil))
        }

        @Test(arguments: [false, true], [false, true])
        func nativeMenuPreservesParticipationStyle(isAttending: Bool, isDeclined: Bool) throws {
            let event = calendarEvent(title: "Planning", isDeclined: isDeclined, isAttending: isAttending)
            let menu = NSHostingMenu(rootView: Menu {
                Button("Join") {}
            } label: {
                Label {
                    HStack { Text(CalendarEventTitle.attributed("12:00 Planning", for: event)) }
                } icon: {
                    Image(systemName: "calendar")
                }
            })
            menu.update()
            let item = try #require(menu.items.first)

            #expect(item.title == "12:00 Planning")
            let attributes = item.attributedTitle?.attributes(at: 0, effectiveRange: nil) ?? [:]
            #expect((attributes[.foregroundColor] != nil) == !event.isAttending)
            #expect((attributes[.strikethroughStyle] as? Int) == (isDeclined ? NSUnderlineStyle.single.rawValue : nil))
            #expect(item.isEnabled)
        }
    }
#endif

private func calendarEvent(title: String, isDeclined: Bool = false, isAttending: Bool = false) -> CalendarEvent {
    let startDate = Date(timeIntervalSince1970: 1_700_000_000)
    return CalendarEvent(
        id: "event-id",
        calendarID: "calendar-id",
        calendarName: "Calendar",
        calendarColorHex: nil,
        platformId: "platform-id",
        title: title,
        description: "",
        icalUid: "uid",
        startDate: startDate,
        endDate: startDate.addingTimeInterval(3600),
        isAllDay: false,
        isDeclined: isDeclined,
        isAttending: isAttending,
        conferenceURI: nil
    )
}
