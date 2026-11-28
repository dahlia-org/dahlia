#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    @Suite(.serialized)
    struct DahliaBotEventRowTests {
        @Test(arguments: [false, true], [false, true])
        func keyboardCanEnterToggleAndLeaveTheEventRow(isExpanded: Bool, hasLink: Bool) async throws {
            let event = AgentEventRecord(
                id: "event", agentID: "agent", sourceID: nil, key: nil, topic: nil, note: "Event note",
                ref: nil, occurredAt: .now, taskID: nil, handledAt: nil, createdAt: .now,
                url: hasLink ? "https://example.com/event" : nil
            )
            var toggles = 0
            var opens = 0
            let host = NSHostingView(rootView: DahliaBotEventRow(
                event: event, icon: Image(systemName: "calendar"), isExpanded: isExpanded, toggle: { toggles += 1 }
            ).environment(\.openURL, OpenURLAction { _ in
                opens += 1
                return .handled
            }).frame(width: 320, height: 80))
            let before = NSTextField(string: "Before")
            let after = NSTextField(string: "After")
            let stack = NSStackView(views: [before, host, after])
            stack.orientation = .vertical
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                styleMask: .titled, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = stack
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            stack.layoutSubtreeIfNeeded()
            try #require(await pollUntil { !focusableLeaves(in: host).isEmpty })
            let targets = focusableLeaves(in: host).sorted { $0.frame.width > $1.frame.width }
            try #require(targets.count == (hasLink ? 2 : 1))
            let target = try #require(targets.first)
            // Use the same explicit key loop as the segmented picker tests, without changing system preferences.
            window.autorecalculatesKeyViewLoop = false
            before.nextKeyView = target
            target.nextKeyView = hasLink ? targets.last : after
            if hasLink { targets.last?.nextKeyView = after }
            try #require(window.makeFirstResponder(before))
            try sendKey("\t", code: 48, to: window)
            try #require(window.firstResponder === target)
            try sendKey(" ", code: 49, to: window)
            try #require(await pollUntil { toggles == 1 })
            try sendKey("\r", code: 36, to: window)
            try #require(await pollUntil { toggles == 2 })
            try click(target, in: window)
            try #require(await pollUntil { toggles == 3 })
            try sendKey("\t", code: 48, to: window)
            if hasLink {
                let link = try #require(targets.last)
                try #require(window.firstResponder === link)
                try sendKey(" ", code: 49, to: window)
                try #require(await pollUntil { opens == 1 })
                try sendKey("\r", code: 36, to: window)
                try #require(await pollUntil { opens == 2 })
                try click(link, in: window)
                try #require(await pollUntil { opens == 3 })
                #expect(toggles == 3)
                try sendKey("\t", code: 48, to: window)
            }
            #expect(after.currentEditor() === window.firstResponder)
        }

        private func focusableLeaves(in view: NSView) -> [NSView] {
            let children = view.subviews.flatMap { focusableLeaves(in: $0) }
            return children.isEmpty && view.acceptsFirstResponder ? [view] : children
        }

        private func click(_ view: NSView, in window: NSWindow) throws {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                ))
                window.sendEvent(event)
            }
        }

        private func sendKey(_ characters: String, code: UInt16, to window: NSWindow) throws {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try #require(NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
                ))
                window.sendEvent(event)
            }
        }
    }
#endif
