#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct CodexChatNoticePresentationTests {
        @Test(arguments: [CGFloat(400), CGFloat(1000)])
        func multilineCommandResultStartsCollapsedAndCanExpandAndCollapse(width: CGFloat) async throws {
            let text = """
            dahlia: connected, 13 tools (direct)
            glean: connected, 8 tools (codemode)
            gmail-read: connected, 7 tools (codemode)
            google-calendar-read: connected, 5 tools (codemode)
            google-drive-read: connected, 10 tools (codemode)
            slack-read: connected, 10 tools (codemode)
            github: connected, 27 tools (codemode)
            atlassian: connected, 22 tools (codemode)
            genie-one: connected, 4 tools (codemode)
            logfood-dbsql: connected, 2 tools (codemode)
            slack: connected, 6 tools (codemode)
            web-search: connected, 1 tools (codemode)
            chrome-work: connected, 29 tools (codemode)
            google: connected, 91 tools (codemode)
            """
            let host = NSHostingView(rootView: CodexChatMessageRow(
                message: CodexChatMessage(role: .notice(.info), text: text),
                showsInlineActivity: false, meetingNamesByID: [:], meetingReferencesByID: [:]
            ).padding(16).frame(width: width))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            #expect(host.frame.height < 100)
            #expect(host.frame.width == width)
            if let directory = ProcessInfo.processInfo.environment["DAHLIA_SLASH_SNAPSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appending(path: "mcp-result-\(Int(width)).png"))
            }
            try clickHeading(in: window)
            #expect(await pollUntil(timeout: .seconds(3)) {
                host.layoutSubtreeIfNeeded()
                return host.fittingSize.height > 250
            })
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            try clickHeading(in: window)
            #expect(await pollUntil(timeout: .seconds(3)) {
                host.layoutSubtreeIfNeeded()
                return host.fittingSize.height < 100
            })
        }

        private func clickHeading(in window: NSWindow) throws {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type,
                    location: NSPoint(x: 60, y: window.contentLayoutRect.height - 28),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1
                ))
                window.sendEvent(event)
            }
        }
    }
#endif
