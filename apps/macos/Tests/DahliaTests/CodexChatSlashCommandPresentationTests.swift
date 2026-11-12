#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    @Suite(.serialized)
    struct CodexChatSlashCommandPresentationTests {
        @Test(arguments: [false, true])
        func candidatesFitTheWindowAndArrowThenTabSelectsTheNextCommand(isBottom: Bool) async throws {
            let service = TestCodexChatService(mode: .complete, commands: [
                .init(name: "mcp", description: "MCP status", source: "extension"),
                .init(name: "skill:meeting-reviewer", description: "Review a meeting", source: "skill"),
                .init(name: "skill:projects-optimizer", description: "Organize projects", source: "skill"),
            ])
            let session = CodexChatSessionModel(workspaceID: .v7(), service: service, runtimeProviderResolver: { .local })
            session.draft = "/"
            let navigation = MainWindowNavigation(openMainWindow: {}, initialSettingsCategory: .general)
            let host = NSHostingView(rootView: VStack(spacing: 0) {
                Spacer(minLength: 0)
                CodexChatComposer(session: session, configurationPresentation: nil)
                if !isBottom { Spacer(minLength: 0) }
            }
            .padding(16)
            .frame(width: 700, height: 500)
            .coordinateSpace(name: CodexChatAddPanelLayout.coordinateSpaceName)
            .environment(navigation))
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            #expect(await pollUntil(timeout: .seconds(3)) {
                host.layoutSubtreeIfNeeded()
                guard let panel = self.panel(in: host), let editor = self.textEditor(in: host) else { return false }
                let panelFrame = window.convertToScreen(panel.convert(panel.bounds, to: nil))
                let editorFrame = window.convertToScreen(editor.convert(editor.bounds, to: nil))
                return panelFrame.minY > editorFrame.maxY && window.convertToScreen(window.contentLayoutRect).contains(panelFrame)
            })
            if let directory = ProcessInfo.processInfo.environment["DAHLIA_SLASH_SNAPSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appending(path: isBottom ? "bottom.png" : "center.png"))
            }
            let panel = try #require(self.panel(in: host))
            let panelFrame = window.convertToScreen(panel.convert(panel.bounds, to: nil))
            #expect(window.convertToScreen(window.contentLayoutRect).contains(panelFrame))
            #expect(panelFrame.width <= 320)
            let editor = try #require(textEditor(in: host))
            if isBottom {
                let editorFrame = window.convertToScreen(editor.convert(editor.bounds, to: nil))
                #expect(panelFrame.minY > editorFrame.maxY)
            }
            #expect(window.makeFirstResponder(editor))
            for (characters, keyCode): (String, UInt16) in [("\u{F701}", 125), ("\t", 48)] {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: keyCode == 125 ? [.function, .numericPad] : [], timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
                ))
                window.sendEvent(event)
            }
            #expect(session.draft == "/skill:meeting-reviewer ")
            #expect(await service.sentTextBlocks.isEmpty)
        }

        private func panel(in view: NSView) -> NSView? {
            // The outside-click monitor is a native NSView whose bounds cover the whole popup.
            if type(of: view) == NSView.self, view.bounds.width == 320, view.bounds.height >= 100 { return view }
            return view.subviews.lazy.compactMap(panel(in:)).first
        }

        private func textEditor(in view: NSView) -> NSTextView? {
            (view as? NSTextView) ?? view.subviews.lazy.compactMap(textEditor(in:)).first
        }
    }
#endif
