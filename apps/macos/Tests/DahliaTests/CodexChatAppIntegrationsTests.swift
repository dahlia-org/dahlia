#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct CodexChatAppIntegrationsTests {
        @Test
        func settingsAndCloseAreIndependentButtons() async throws {
            var settingsOpened = 0
            var dismissals = 0
            let host = NSHostingView(rootView: CodexChatAppIntegrationsView(
                onOpenSettings: { settingsOpened += 1 },
                onDismiss: { dismissals += 1 }
            ))
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 36)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()

            try click(x: 100, in: window)
            #expect(await pollUntil(timeout: .seconds(2)) { settingsOpened == 1 })
            #expect(dismissals == 0)

            try click(x: 682, in: window)
            #expect(await pollUntil(timeout: .seconds(2)) { dismissals == 1 })
            #expect(settingsOpened == 1)
        }

        @Test(arguments: [
            "IntegrationSlack", "IntegrationGmail", "IntegrationGoogleDrive", "IntegrationGitHub", "IntegrationAtlassian",
            "IntegrationGoogleCalendar", "IntegrationMicrosoft365", "IntegrationGenie", "IntegrationDBSQL",
        ])
        func bundledAppIconsCanBeLoaded(name: String) throws {
            let image = try #require(Bundle.appModule.image(forResource: name))
            #expect(image.isValid)
        }

        private func click(x: CGFloat, in window: NSWindow) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: CGPoint(x: x, y: 18), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                ))
                window.sendEvent(event)
            }
        }
    }
#endif
