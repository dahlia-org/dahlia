#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    @Suite(.serialized)
    struct AgentIdentityRowTests {
        @Test(arguments: [false, true])
        func leavingTheRowSavesButEscapeCancels(cancel: Bool) async throws {
            let agent = AgentRecord(
                id: UUID.v7().uuidString, name: "Original", directory: "original", avatar: "mascot:E1", color: "#b3dbf4",
                createdAt: .now, updatedAt: .now
            )
            var savedNames: [String] = []
            let host = NSHostingView(rootView: AnyView(AgentIdentityRow(agent: agent) { name, avatar, color in
                savedNames.append(name)
                var saved = agent
                saved.name = name
                saved.avatar = avatar
                saved.color = color
                return (saved, nil)
            }))
            host.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()

            // Open the name editor by clicking the name, beyond the avatar.
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: CGPoint(x: 100, y: 22), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                ))
                window.sendEvent(event)
            }
            try #require(await pollUntil { window.firstResponder is NSTextView })
            let editor = try #require(window.firstResponder as? NSTextView)
            editor.insertText("Renamed", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            #expect(editor.string == "Renamed")

            if cancel {
                let escape = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53
                ))
                window.sendEvent(escape)
                try #require(await pollUntil { !(window.firstResponder is NSTextView) })
            }

            // A tab/panel change removes the editor without first delivering focus loss.
            host.rootView = AnyView(Color.clear)
            host.layoutSubtreeIfNeeded()
            if cancel {
                #expect(savedNames.isEmpty)
            } else {
                #expect(await pollUntil { savedNames == ["Renamed"] })
            }
        }

    }
#endif
