#if canImport(Testing)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Dahlia

    @MainActor
    struct AgentMCPSettingsViewTests {
        @Test func eventSourceChoicesExcludeSearchDriveAndCalendarEvenWithCustomServerNames() throws {
            let provider = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://workspace.example.com")))
            let services = ["gmail", "google_calendar", "slack", "web_search", "google_drive"]
            let settings = AgentMCPSettings(providers: [provider], servers: services.enumerated().map { index, service in
                AgentMCPServer(id: .v7(), name: "connector_\(index)", providerID: provider.id, service: "system.ai.\(service)")
            })
            #expect(DahliaBotPanelModel.sourceServers(in: settings, providers: settings.providers) == ["connector_0", "connector_2"])
            #expect(settings.piServers.count == 5)
        }

        @Test func eventSourceDefaultsFollowSettingsSectionsAndServiceOrder() throws {
            let first = AgentMCPProvider(workspaceURL: try #require(URL(string: "https://first.example.com")))
            let second = AgentMCPProvider(workspaceURL: try #require(URL(string: "https://second.example.com")))
            let settings = AgentMCPSettings(providers: [second, first], servers: [
                AgentMCPServer(id: .v7(), name: "second_slack", providerID: second.id, service: "system.ai.slack"),
                AgentMCPServer(id: .v7(), name: "custom_slack", providerID: first.id, service: "main.team.slack"),
                AgentMCPServer(id: .v7(), name: "first_slack", providerID: first.id, service: "system.ai.slack"),
                AgentMCPServer(id: .v7(), name: "local_slack", providerID: nil, service: "local_slack",
                               direct: AgentMCPDirectConfiguration(command: "slack-mcp")),
                AgentMCPServer(id: .v7(), name: "disabled_slack", providerID: nil, service: "disabled_slack",
                               direct: AgentMCPDirectConfiguration(isEnabled: false, command: "slack-mcp")),
            ])
            let model = DahliaBotPanelModel()
            model.servers = DahliaBotPanelModel.sourceServers(in: settings, providers: [first, second])
            #expect(model.servers == ["local_slack", "first_slack", "custom_slack", "second_slack"])
            model.edit(nil)
            #expect(model.draft?.server == "local_slack")
        }

        @Test(arguments: ["system.ai.google_drive", "system.ai.google_calendar", "system.ai.web_search"])
        func existingExcludedSourceKeepsItsRegisteredConnectionLabel(service: String) throws {
            let provider = AgentMCPProvider(workspaceURL: try #require(URL(string: "https://workspace.example.com")))
            let settings = AgentMCPSettings(providers: [provider], servers: [
                AgentMCPServer(id: .v7(), name: "existing", providerID: provider.id, service: service),
            ])
            let source = AgentSourceRecord(
                id: "source", agentID: "agent", name: "Existing", server: "existing", instructions: "Read updates",
                intervalMinutes: 15, allowedSenders: "[]", enabled: true, createdAt: .now, updatedAt: .now,
                connectionID: try #require(settings.connectionID(for: "existing"))
            )
            let model = DahliaBotPanelModel()
            model.sources = [source]
            model.loadConnectors(settings, providers: [provider])
            #expect(model.servers.isEmpty)
            #expect(model.sourceChoiceName(source.id) == "existing (workspace.example.com)")
        }

        @Test func existingSourceLabelRejectsReplacedOrUnavailableConnections() {
            let model = DahliaBotPanelModel()
            let source = AgentSourceRecord(
                id: "source", agentID: "agent", name: "Slack", server: "slack", instructions: "Read mentions",
                intervalMinutes: 15, allowedSenders: "[]", enabled: true, createdAt: .now, updatedAt: .now,
                connectionID: "original"
            )
            model.sources = [source]
            model.providers = ["slack": "original.example.com"]
            model.connections = ["slack": "original"]
            #expect(model.sourceChoiceName(source.id) == "slack (original.example.com)")
            model.providers = ["slack": "replacement.example.com"]
            model.connections = ["slack": "replacement"]
            #expect(model.sourceChoiceName(source.id) == "slack (\(L10n.agentAlwaysOnConnectionUnavailable))")
            #expect(model.choiceName("slack") == "slack (replacement.example.com)")
            model.connections = [:]
            #expect(model.sourceChoiceName(source.id) == "slack (\(L10n.agentAlwaysOnConnectionUnavailable))")
        }

        @Test func eventSourceGroupsSlackServersAndStartsFromTheTopOne() {
            let model = DahliaBotPanelModel()
            model.servers = ["gmail", "work-slack", "jira", "connector_9"]
            model.services = ["connector_9": "system.ai.slack", "jira": "system.ai.atlassian"]
            #expect(model.serverGroups == [["gmail"], ["work-slack", "connector_9"], ["jira"]])
            model.edit(nil)
            model.choose(server: "work-slack")
            #expect(model.draft?.instructions == L10n.agentAlwaysOnSuggestedSlack)
            model.choose(server: "connector_9")
            #expect(model.draft?.server == "connector_9" && model.draft?.instructions == L10n.agentAlwaysOnSuggestedSlack)
            model.choose(server: "jira")
            #expect(model.draft?.instructions.isEmpty == true)
            model.providers = ["gmail": "workspace.example.com", "jira": ""]
            #expect(model.choiceName("gmail") == "gmail (workspace.example.com)" && model.choiceName("jira") == "jira")
        }

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
            AgentMCPSettings(providers: [provider]).save(defaults: defaults)
            let list = try String(decoding: JSONEncoder().encode(services), as: UTF8.self)
            let runtime = TestPiRuntime { _ in
                TestPiTransport { _ in
                    [TestPiTransport.notify("databricks:mcp_services \(list)")]
                }
            }
            let model = AgentMCPSettingsModel(service: runtime.service, defaults: defaults)
            try model.setService("system.ai.github", enabled: true, of: provider)
            try model.setService("system.ai.atlassian", enabled: true, of: provider)
            try model.setService("system.ai.sandbox", enabled: true, of: provider)
            try model.setService("system.ai.genie_one_mcp", enabled: true, of: provider)
            try model.setService("system.ai.dbsql", enabled: true, of: provider)
            await model.refreshServices(of: provider)
            try model.addService("main.default.notion", to: provider)
            let host = NSHostingView(rootView: AgentMCPSettingsView(model: model, onAdd: { _ in }, onEditDirect: { _ in })
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
