import AppKit
import SwiftUI
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct MCPSettingsViewTests {
        @Test(arguments: [640.0, 900.0])
        func setupFitsSettingsWidth(width: Double) throws {
            var serverWorkspace = WorkspaceRecord(id: .v7(), name: "Default", createdAt: .distantPast, lastOpenedAt: .distantPast)
            let accountID = UUID.v7()
            serverWorkspace.accountConnectionId = accountID
            let local = WorkspaceRecord(id: .v7(), name: "Default", createdAt: .distantPast, lastOpenedAt: .distantPast)
            let connection = DahliaAccountConnection(
                record: DahliaAccountConnectionRecord(
                    id: accountID,
                    origin: "https://meetings.example.com",
                    clientID: "test",
                    createdAt: .distantPast
                ),
                account: nil, isCloud: false
            )
            let host = NSHostingView(rootView: MCPSettingsView(
                workspaces: [local, serverWorkspace], currentWorkspace: local,
                accountConnections: [connection], databricksAccounts: [],
                helperURL: URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/dahlia-mcp")
            ).background(Color(nsColor: .windowBackgroundColor)))
            host.sizingOptions = .intrinsicContentSize
            host.frame = NSRect(x: 0, y: 0, width: width, height: 1100)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            #expect(abs(host.frame.width - width) < 1)
            let controls = controls(in: host)
            #expect(!controls.isEmpty)
            for control in controls where !control.isHiddenOrHasHiddenAncestor {
                let frame = host.convert(control.bounds, from: control)
                #expect(frame.minX >= 0)
                #expect(frame.maxX <= width)
            }

            if let directory = ProcessInfo.processInfo.environment["DAHLIA_MCP_SETUP_SNAPSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(filePath: directory).appending(path: "setup-\(Int(width)).png"))
            }
        }

        @Test(arguments: [140.0, 330.0])
        func disclosureHeadingOpensAndClosesAwayFromChevron(x: Double) async throws {
            var expanded = false
            var labelHeight: CGFloat = 0
            let host = NSHostingView(rootView: DisclosureGroup(isExpanded: Binding(
                get: { expanded }, set: { expanded = $0 }
            )) {
                Text("Default - Local Account")
            } label: {
                Text("Included workspaces (1)")
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { labelHeight = $0 }
            }
            .disclosureGroupStyle(MCPDisclosureGroupStyle())
            .font(.dahliaBody)
            .frame(width: 360, height: 100, alignment: .topLeading))
            host.frame = CGRect(x: 0, y: 0, width: 360, height: 100)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            try #require(await pollUntil { labelHeight > 0 })

            for expected in [true, false] {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(
                        with: type, location: CGPoint(x: x, y: 100 - labelHeight / 2), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                    ))
                    window.sendEvent(event)
                }
                try #require(await pollUntil { expanded == expected })
                host.layoutSubtreeIfNeeded()
            }
        }

        private func controls(in view: NSView) -> [NSControl] {
            (view as? NSControl).map { [$0] } ?? view.subviews.flatMap(controls(in:))
        }
    }
#endif
