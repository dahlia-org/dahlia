#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct AgentMCPSettingsViewTests {
        @Test(arguments: [CGFloat(560), CGFloat(1200)])
        func catalogStaysCenteredAndBoundedWithLongDescriptions(width: CGFloat) async throws {
            let suite = "AgentMCPSettingsViewTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let provider = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://workspace.example.com")))
            let services = [
                AgentMCPService(name: "system.ai.github", comment: "Search repositories, issues, pull requests, and code.", signInState: .signedIn),
                AgentMCPService(
                    name: "system.ai.google_drive",
                    comment: String(repeating: "Search Google Docs, Sheets, Slides, and other Drive files. ", count: 3), signInState: .signInRequired
                ),
                AgentMCPService(name: "system.ai.atlassian", comment: "Search Jira and Confluence.", signInState: .signInRequired),
                AgentMCPService(name: "system.ai.sandbox", comment: "Run code in an isolated environment."),
                AgentMCPService(name: "system.ai.genie_one_mcp", comment: "Ask questions about your data."),
                AgentMCPService(name: "system.ai.dbsql", comment: "Run SQL queries."),
                AgentMCPService(name: "system.ai.web_search", comment: "Search the public web."),
            ]
            AgentMCPSettings(providers: [provider]).save(for: .local, defaults: defaults)
            let list = try String(decoding: JSONEncoder().encode(services), as: UTF8.self)
            let runtime = TestPiRuntime { _ in
                TestPiTransport { _ in
                    [TestPiTransport.notify("databricks:mcp_services \(list)")]
                }
            }
            let model = AgentMCPSettingsModel(account: .local, service: runtime.service, defaults: defaults)
            try model.setService("system.ai.github", enabled: true, of: provider)
            try model.setService("system.ai.atlassian", enabled: true, of: provider)
            try model.setService("system.ai.sandbox", enabled: true, of: provider)
            try model.setService("system.ai.genie_one_mcp", enabled: true, of: provider)
            try model.setService("system.ai.dbsql", enabled: true, of: provider)
            await model.refreshServices(of: provider)
            try model.addService("main.default.notion", to: provider)
            let host = NSHostingView(rootView: AgentMCPSettingsView(model: model, onAdd: { _ in })
                .background(Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
            let window = NSWindow(contentRect: host.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            let search = try #require(textFields(in: host).first { $0.isEditable })
            let frame = host.convert(search.bounds, from: search)
            #expect(frame.width > 0)
            #expect(frame.width <= 700)
            #expect(frame.minX >= 16)
            #expect(frame.maxX <= width - 16)
            #expect(abs(frame.midX - width / 2) <= 2)
            #expect(host.fittingSize.width <= 740)

            if let directory = ProcessInfo.processInfo.environment["DAHLIA_MCP_SETTINGS_SNAPSHOTS"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appending(path: "catalog-\(Int(width)).png"))
            }
        }

        private func textFields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields(in:))
        }
    }
#endif
