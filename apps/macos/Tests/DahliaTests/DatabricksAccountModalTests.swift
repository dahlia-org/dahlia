#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct DatabricksAccountModalTests {
        @Test
        func backgroundClicksKeepTheModalOpenAndEscapeCancels() async throws {
            var cancellations = 0
            let content = AnyView(DatabricksSignInView(
                onCancel: { cancellations += 1 }, onContinueWithDatabricks: { _ in }, onContinueLocally: {}
            ))
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 12, y: 12), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
                ))
                window.sendEvent(event)
            }
            #expect(cancellations == 0)

            if let directory = ProcessInfo.processInfo.environment["DAHLIA_ACCOUNT_MODAL_SNAPSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appending(path: "sign-in.png"))
            }

            let escape = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53
            ))
            window.sendEvent(escape)
            #expect(await pollUntil(timeout: .seconds(2)) { cancellations == 1 })
        }
    }
#endif
