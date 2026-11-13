#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct MainSidebarUpcomingEventRowTests {
        @Test(arguments: [false, true])
        func highlightedSpaceSelectsEvent(hasConferenceLink: Bool) async throws {
            var selections = 0
            var joins = 0
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let event = CalendarEvent(
                id: "event", calendarID: "calendar", calendarName: "Calendar", calendarColorHex: nil,
                platformId: "event", title: "Example", description: "", icalUid: nil,
                startDate: start, endDate: start.addingTimeInterval(3600), isAllDay: false,
                conferenceURI: hasConferenceLink ? URL(string: "https://meet.google.com/abc") : nil
            )
            let host = NSHostingView(rootView: MainSidebarUpcomingEventRow(
                event: event, now: start, isSelected: false, canStartRecording: true,
                isAutoRecordingEnabled: false, onSelect: { selections += 1 }, onJoin: { joins += 1 },
                onOpenMeetingLink: {}, onSetAutoRecording: { _ in }
            )
            .environment(DahliaWindowHeaderHelpController())
            .font(.dahliaBody))
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            // Keep the real pointer from revealing actions over the reserved time area.
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            host.layoutSubtreeIfNeeded()

            // The reserved time area selects the event while the hover actions are hidden.
            try click(x: 250, in: window)
            #expect(await pollUntil(timeout: .seconds(2)) { selections == 1 })
            #expect(joins == 0)

            try click(x: 50, in: window)
            #expect(await pollUntil(timeout: .seconds(2)) { selections == 2 })

        }

        private func click(x: CGFloat, in window: NSWindow) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: CGPoint(x: x, y: 14), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                ))
                window.sendEvent(event)
            }
        }
    }
#endif
