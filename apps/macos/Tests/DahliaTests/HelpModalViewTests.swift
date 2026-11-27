#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct HelpModalViewTests {
        @Test(arguments: ["outside", "close", "escape"])
        func dismissesThroughEveryExit(exit: String) async throws {
            var closeCount = 0
            var isLaidOut = false
            let host = NSHostingView(rootView: HelpModalView(onClose: { closeCount += 1 }, onOpenSettings: { _ in })
                .onGeometryChange(for: CGSize.self) { $0.size } action: { isLaidOut = $0.width > 0 })
            host.frame = CGRect(x: 0, y: 0, width: 1100, height: 850)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            try #require(await pollUntil { isLaidOut })

            // Blank space in the header belongs to the card, not its dismissing backdrop.
            try click(CGPoint(x: 550, y: 790), in: window)
            #expect(closeCount == 0)

            switch exit {
            case "outside":
                try click(CGPoint(x: 12, y: 12), in: window)
            case "close":
                let point = CGPoint(
                    x: 1040 - DahliaDesign.windowHeaderHorizontalPadding - DahliaDesign.windowHeaderControlSize / 2,
                    y: 805 - DahliaDesign.windowHeaderHeight / 2
                )
                try click(point, in: window)
            default:
                let escape = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53
                ))
                NSApplication.shared.sendEvent(escape)
            }
            #expect(await pollUntil { closeCount == 1 })
        }

        private func click(_ point: CGPoint, in window: NSWindow) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                ))
                NSApplication.shared.sendEvent(event)
            }
        }
    }
#endif
