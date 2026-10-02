#if canImport(Testing)
    import AppKit
    import Testing
    import WebKit
    @testable import Dahlia

    @MainActor
    struct DocumentEditorShortcutTests {
        @Test
        func documentHeightAcceptsOnlyPositiveFiniteValues() {
            var heights: [CGFloat] = []
            var editor = parent(editable: true)
            editor.onHeight = { heights.append($0) }
            let coordinator = DocumentWebEditor.Coordinator(parent: editor)
            for raw in ["280", "720.5", "0", "-1", "nan", "inf", "invalid"] {
                coordinator.receive(["type": "height", "height": raw])
            }
            coordinator.receive(["type": "height"])
            #expect(heights == [280, 720.5])
        }

        @Test
        func commandBReachesFocusedNotesBeforeWindowShortcuts() throws {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            let webView = WKWebView()
            let content = NSView()
            window.contentView = content
            content.addSubview(webView)
            let input = ShortcutInputView()
            webView.addSubview(input)
            #expect(window.makeFirstResponder(input))
            let coordinator = DocumentWebEditor.Coordinator(parent: parent(editable: true))
            coordinator.view = webView
            let commandB = try event(window: window, characters: "b", modifiers: .command)
            #expect(coordinator.handleKeyDown(commandB) == nil)
            #expect(input.keys == ["b"])

            for (characters, modifiers): (String, NSEvent.ModifierFlags) in [("b", []), ("b", [.command, .shift]), ("f", .command)] {
                let other = try event(window: window, characters: characters, modifiers: modifiers)
                #expect(coordinator.handleKeyDown(other) === other)
            }
            coordinator.parent = parent(editable: false)
            #expect(coordinator.handleKeyDown(commandB) === commandB)
            coordinator.parent = parent(editable: true)
            let outside = ShortcutInputView()
            content.addSubview(outside)
            #expect(window.makeFirstResponder(outside))
            #expect(coordinator.handleKeyDown(commandB) === commandB)
            #expect(input.keys == ["b"])
            #expect(outside.keys.isEmpty)
        }

        private func parent(editable: Bool) -> DocumentWebEditor {
            DocumentWebEditor(
                checkpoint: "", receivedUpdate: "", receivedVector: "", editable: editable,
                onUpdate: { _, _ in }, onError: { _ in }, onFocus: { _ in }, onAttachFlush: { _ in }
            )
        }

        private func event(window: NSWindow, characters: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 11
            ))
        }
    }

    @MainActor
    private final class ShortcutInputView: NSView {
        var keys: [String] = []
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { keys.append(event.charactersIgnoringModifiers ?? "") }
    }
#endif
