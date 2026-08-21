import AppKit
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct MeetingNotificationPopupTests {
        @Test
        func offersJoinActionsWhenConferenceLinkExists() {
            let popup = makePopup(id: "calendar", event: makeCalendarEvent())

            #expect(popup.actions == [.joinAndStartRecording, .join, .close])
        }

        @Test
        func offersRecordingActionWithoutConferenceLink() {
            let popup = makePopup(id: "microphone", event: nil)

            #expect(popup.actions == [.startRecording, .close])
        }

        @Test
        func usesIconsThatMatchEachAction() {
            #expect(MeetingNotificationPopup.Action.joinAndStartRecording.systemImage == "video.badge.waveform.fill")
            #expect(MeetingNotificationPopup.Action.join.systemImage == "video.fill")
            #expect(MeetingNotificationPopup.Action.startRecording.systemImage == "mic.and.signal.meter.fill")
        }

        @Test
        func exposesNonemptyCalendarDescription() {
            let event = makeCalendarEvent(description: "Agenda and notes")
            let popup = makePopup(id: "calendar", event: event)

            #expect(popup.calendarDescription == "Agenda and notes")
        }

        @Test
        func boundsAndRemovesMarkupFromCalendarDescription() {
            let longDescription = "<div>Agenda <strong>& notes</strong></div>" + String(repeating: "x", count: 5000)
            let popup = makePopup(id: "calendar", event: makeCalendarEvent(description: longDescription))

            #expect(popup.calendarDescription?.hasPrefix("Agenda & notes") == true)
            #expect(popup.calendarDescription?.contains("<") == false)
            #expect((popup.calendarDescription?.count ?? 0) <= 4000)
        }

        @Test
        func routesEachActionToItsCallback() {
            let meeting = makePopup(id: "meeting").meeting
            var performed: [String] = []
            let actions: [MeetingNotificationPopup.Action] = [
                .startRecording,
                .join,
                .joinAndStartRecording,
                .close,
            ]

            for action in actions {
                action.perform(
                    for: meeting,
                    onStartRecording: { _ in performed.append("record") },
                    onJoinMeeting: { _ in performed.append("join") },
                    onJoinAndStartRecording: { _ in performed.append("joinAndRecord") }
                )
            }

            #expect(performed == ["record", "join", "joinAndRecord"])
        }

        @Test
        func deduplicatesAndAdvancesInFIFOOrder() {
            var queue = MeetingNotificationPopupQueue()
            let first = makePopup(id: "first", title: "First")
            let updatedFirst = makePopup(id: "first", title: "Updated")
            let second = makePopup(id: "second", title: "Second")

            let firstBecameCurrent = queue.enqueue(first)
            let updateBecameCurrent = queue.enqueue(updatedFirst)
            let secondBecameCurrent = queue.enqueue(second)
            #expect(firstBecameCurrent)
            #expect(updateBecameCurrent)
            #expect(!secondBecameCurrent)
            #expect(queue.current?.title == "Updated")
            #expect(queue.pending.map(\.id) == ["second"])

            let next = queue.advance()
            #expect(next?.id == "second")
            #expect(queue.pending.isEmpty)
        }

        @Test
        func removesOnlyCalendarNotifications() {
            var queue = MeetingNotificationPopupQueue()
            let calendar = makePopup(id: "calendar", event: makeCalendarEvent(), isCalendarNotification: true)
            let microphone = makePopup(id: "microphone")

            _ = queue.enqueue(calendar)
            _ = queue.enqueue(microphone)

            let removedCurrent = queue.removeCalendarNotifications()
            #expect(removedCurrent)
            #expect(queue.current?.id == "microphone")
        }

        @Test
        func removesCalendarNotificationsMissingFromReplacementSchedule() {
            var queue = MeetingNotificationPopupQueue()
            _ = queue.enqueue(makePopup(id: "stale", event: makeCalendarEvent(), isCalendarNotification: true))
            _ = queue.enqueue(makePopup(id: "kept", event: makeCalendarEvent(), isCalendarNotification: true))
            _ = queue.enqueue(makePopup(id: "microphone"))

            let removedCurrent = queue.retainCalendarNotifications(withIdentifiers: ["kept"])

            #expect(removedCurrent)
            #expect(queue.current?.id == "kept")
            #expect(queue.pending.map(\.id) == ["microphone"])
        }

        @Test
        func removesOnlyMicrophoneNotifications() {
            var queue = MeetingNotificationPopupQueue()
            _ = queue.enqueue(makePopup(id: "microphone"))
            _ = queue.enqueue(makePopup(id: "calendar", event: makeCalendarEvent(), isCalendarNotification: true))

            let removedCurrent = queue.removeMicrophoneNotifications()

            #expect(removedCurrent)
            #expect(queue.current?.id == "calendar")
            #expect(queue.pending.isEmpty)
        }

        @Test
        func centersPanelInVisibleScreenFrame() {
            let origin = MeetingNotificationPopupLayout.origin(
                panelSize: NSSize(width: 520, height: 240),
                visibleScreenFrame: NSRect(x: 1440, y: 24, width: 1920, height: 1056)
            )

            #expect(origin == NSPoint(x: 2140, y: 432))
        }
    }
#endif

private func makePopup(
    id: String,
    title: String = "Planning",
    event: CalendarEvent? = nil,
    isCalendarNotification: Bool = false
) -> MeetingNotificationPopup {
    MeetingNotificationPopup(
        id: id,
        meeting: DetectedMeeting(
            title: title,
            appName: "Meet",
            bundleIdentifier: "com.example.meet",
            calendarEvent: event
        ),
        title: title,
        subtitle: nil,
        body: "Body",
        isCalendarNotification: isCalendarNotification
    )
}

private func makeCalendarEvent(description: String = "") -> CalendarEvent {
    CalendarEvent(
        id: "event-id",
        calendarID: "calendar-id",
        calendarName: "Work",
        calendarColorHex: nil,
        platformId: "event-id",
        title: "Planning",
        description: description,
        icalUid: "uid",
        startDate: .now.addingTimeInterval(600),
        endDate: .now.addingTimeInterval(4_200),
        isAllDay: false,
        conferenceURI: URL(string: "https://meet.example.com/planning")
    )
}
