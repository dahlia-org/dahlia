#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct CodexChatAddPanelTests {
        @Test(arguments: [CGSize(width: 700, height: 600), CGSize(width: 320, height: 360)], [false, true])
        func addMenuKeepsTheComposerInPlaceAndOpensConnectorsToTheRight(size: CGSize, isEmpty: Bool) async throws {
            let suite = "CodexChatAddPanelTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AgentMCPSettings(servers: isEmpty ? [] : [
                AgentMCPServer(id: .v7(), name: "github", providerID: "workspace.example.com", service: "system.ai.github"),
                AgentMCPServer(id: .v7(), name: "slack", providerID: "workspace.example.com", service: "system.ai.slack"),
            ])
            settings.save(for: .local, defaults: defaults)
            let navigation = MainWindowNavigation(openMainWindow: {}, initialSettingsCategory: .general, settingsDefaults: defaults)
            let session = CodexChatSessionModel(service: TestCodexChatService(mode: .complete), runtimeProviderResolver: { .local })
            let composer = CodexChatComposer(session: session, configurationPresentation: nil, mcpSettingsDefaults: defaults)
            let measurement = NSHostingView(rootView: composer.environment(navigation))
            measurement.frame.size.width = size.width
            let composerHeight = measurement.fittingSize.height
            let host = NSHostingView(rootView: VStack(spacing: 0) {
                Spacer(minLength: 0)
                composer
                Spacer(minLength: 0)
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: CodexChatAddPanelLayout.coordinateSpaceName)
            .environment(navigation))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let editor = try #require(textEditor(in: host))
            let editorFrame = host.convert(editor.bounds, from: editor)
            let plusCenterY = (size.height - composerHeight) / 2 + 21

            try click(CGPoint(x: 21, y: plusCenterY), in: window)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            #expect(host.convert(editor.bounds, from: editor) == editorFrame)
            try snapshot(host, name: "menu-\(Int(size.width))")

            // Three 30-point rows, 2-point gaps, and 10-point panel padding.
            try click(CGPoint(x: 100, y: plusCenterY - 112), in: window)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            #expect(host.convert(editor.bounds, from: editor) == editorFrame)
            try snapshot(host, name: "servers-\(Int(size.width))")

            // The server list may flip above the button in the compact window.
            let bounds = CGRect(x: -6, y: -(size.height - plusCenterY - 15), width: size.width, height: size.height)
            let panelWidth = CodexChatAddPanelLayout.width(windowBounds: bounds, showsSubmenu: true)
            let connectors = NSHostingView(rootView: CodexChatMCPServersView(settings: settings, onOpenSettings: {})
                .frame(width: panelWidth)
                .frame(maxHeight: CodexChatAddPanelLayout.maximumHeight(windowBounds: bounds))
                .fixedSize(horizontal: false, vertical: true))
            let panelHeight = max(114, connectors.fittingSize.height)
            let combinedWidth = panelWidth * 2 + CodexChatAddPanelLayout.submenuSpacing
            let offset = CodexChatAddPanelLayout.offset(panelSize: CGSize(width: combinedWidth, height: panelHeight), windowBounds: bounds)
            let settingsX = 6 + offset.width + panelWidth + CodexChatAddPanelLayout.submenuSpacing + panelWidth / 2
            let settingsY = plusCenterY + 15 - offset.height - panelHeight + 25
            try click(CGPoint(x: settingsX, y: settingsY), in: window)
            #expect(await pollUntil(timeout: .seconds(2)) { navigation.isShowingSettings })
            #expect(navigation.settingsCategory == .agents)
            #expect(navigation.agentSettingsTab == .mcps)
        }

        @Test
        func openingConnectorsKeepsTheOriginalMenuBottomAligned() throws {
            var attachments = 0
            let panel = CodexChatAddPanel(
                windowBounds: CGRect(x: 0, y: -500, width: 700, height: 600),
                showsMeetingPicker: false,
                showsConnectors: true,
                meetingReferences: [],
                highlightedMeetingID: nil,
                mcpSettings: AgentMCPSettings(servers: (0 ..< 5).map {
                    AgentMCPServer(id: .v7(), name: "github_\($0)", providerID: nil, service: "system.ai.github")
                }),
                onAttachImages: { attachments += 1 },
                onAddMeetingReference: {},
                onSelectMeeting: { _ in },
                onOpenMCPSettings: {}
            )
            let host = NSHostingView(rootView: panel
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 700, height: 400, alignment: .bottomLeading))
            host.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            try click(CGPoint(x: 100, y: 25), in: window)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try snapshot(host, name: "bottom-aligned-connectors")
            // Opening a taller submenu must leave the original attachment row reachable in place.
            try click(CGPoint(x: 100, y: 89), in: window)
            #expect(attachments == 1)
        }

        @Test(arguments: [false, true])
        func onlyNewChatsIncludeTheConnectorRow(isNewChat: Bool) {
            let panel = CodexChatAddPanel(
                windowBounds: CGRect(x: 0, y: -500, width: 700, height: 600),
                showsMeetingPicker: false,
                showsConnectors: isNewChat,
                meetingReferences: [],
                highlightedMeetingID: nil,
                mcpSettings: AgentMCPSettings(),
                onAttachImages: {},
                onAddMeetingReference: {},
                onSelectMeeting: { _ in },
                onOpenMCPSettings: {}
            )
            let host = NSHostingView(rootView: panel)
            host.frame.size.width = 280
            // Existing chats keep the attachment/reference rows and omit the connector row and its spacing.
            #expect(host.fittingSize.height == (isNewChat ? 114 : 82))
        }

        private func textEditor(in view: NSView) -> NSTextView? {
            (view as? NSTextView) ?? view.subviews.lazy.compactMap(textEditor(in:)).first
        }

        private func click(_ point: CGPoint, in window: NSWindow) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                ))
                window.sendEvent(event)
            }
        }

        private func snapshot(_ host: NSView, name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["DAHLIA_CHAT_ADD_PANEL_SNAPSHOTS"] else { return }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
        }
    }
#endif
