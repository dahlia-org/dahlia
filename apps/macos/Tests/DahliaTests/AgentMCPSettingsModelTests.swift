import DahliaRuntimeSupport
import Foundation
import os
@testable import Dahlia

#if canImport(Testing)
    import Testing

    private let accountConnectionID = UUID()

    @MainActor
    @Suite(.providerAccounts([.init(id: accountConnectionID, workspaceURL: URL(string: "https://account.cloud.databricks.com")!)]))
    struct AgentMCPSettingsModelTests {

        /// Pi answers `/databricks-login` with an authorization URL and `succeeds`, `/databricks-mcp-services` with
        /// `services` (or sign-in required when nil), and `/dahlia-logout` with a response.
        private static func runtime(
            succeeds: Bool = true,
            logoutSucceeds: Bool = true,
            services: [AgentMCPService]? = [
                .init(name: "system.ai.github", comment: "Search repositories", signInState: .signedIn),
                .init(name: "system.ai.slack"),
            ],
            commands: OSAllocatedUnfairLock<[String]>
        ) -> TestPiRuntime {
            TestPiRuntime { _ in
                TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    let message = command["message"]?.stringValue ?? ""
                    commands.withLock { $0.append(message) }
                    if message.hasPrefix("/databricks-login") {
                        return [
                            TestPiTransport.notify("databricks:auth_url https://example.cloud.databricks.com/oidc/v1/authorize"),
                            TestPiTransport.notify(succeeds ? "databricks:login_succeeded" : "databricks:login_failed denied"),
                        ]
                    }
                    if message.hasPrefix("/databricks-connection-login") {
                        return [
                            TestPiTransport.notify("databricks:connection_auth_url https://example.cloud.databricks.com/oidc/v1/authorize"),
                            TestPiTransport.notify("databricks:connection_login_succeeded"),
                        ]
                    }
                    if message.hasPrefix("/databricks-mcp-services") {
                        let list = services.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
                        return [TestPiTransport.notify(list.map { "databricks:mcp_services \($0)" } ?? "databricks:mcp_services_sign_in_required")]
                    }
                    if message.hasPrefix("/dahlia-logout"), !logoutSucceeds {
                        return [.object(["type": .string("response"), "id": id, "success": .bool(false), "error": .string("Pi failed")])]
                    }
                    return [TestPiTransport.response(id: id)]
                }
            }
        }

        /// A workspace added before every Databricks connection was a provider account; Pi holds its sign-in.
        private static let legacyWorkspace = AgentMCPProvider(workspaceURL: URL(string: "https://example.cloud.databricks.com")!)

        private static func model(
            _ pi: TestPiRuntime,
            urlOpener: TestCodexLoginURLOpener = TestCodexLoginURLOpener(),
            settings: AgentMCPSettings = AgentMCPSettings(),
            signInWorkspace: @escaping @Sendable (String) async throws -> DatabricksConnection = { _ in
                Issue.record("Unexpected sign-in")
                throw CancellationError()
            }
        ) throws -> (AgentMCPSettingsModel, UserDefaults) {
            let defaults = try #require(UserDefaults(suiteName: "AgentMCPSettingsModelTests.\(UUID())"))
            settings.save(defaults: defaults)
            let model = AgentMCPSettingsModel(
                service: pi.service,
                urlOpener: urlOpener,
                defaults: defaults,
                signInWorkspace: signInWorkspace
            )
            return (model, defaults)
        }

        @Test
        func aWorkspaceIsAddedAsAProviderAccountThroughTheAppsSignIn() async throws {
            let commands = OSAllocatedUnfairLock<[String]>(initialState: [])
            let signIns = OSAllocatedUnfairLock<[String]>(initialState: [])
            let (model, defaults) = try Self.model(Self.runtime(commands: commands)) { url in
                signIns.withLock { $0.append(url) }
                return DatabricksConnection(id: .v7(), host: url)
            }

            let provider = try await model.addWorkspace(workspaceURL: "https://Example.cloud.databricks.com/")
            // The ID follows the workspace URL; Settings shows its host. The app holds the sign-in, not Pi.
            #expect(provider.id == "example.cloud.databricks.com" && provider.host == "example.cloud.databricks.com")
            #expect(signIns.withLock { $0 } == ["https://example.cloud.databricks.com"])
            #expect(commands.withLock { $0 }.isEmpty)
            #expect(AgentMCPSettings.load(defaults: defaults) == AgentMCPSettings())
            // The account's connection is a provider account already.
            await #expect(throws: AgentMCPSettingsError.self) {
                _ = try await model.addWorkspace(workspaceURL: "https://account.cloud.databricks.com")
            }
            #expect(signIns.withLock { $0 }.count == 1)
        }

        @Test
        func aWorkspaceAddedBeforeSharesItsPiSignInWithItsChosenServices() async throws {
            let commands = OSAllocatedUnfairLock<[String]>(initialState: [])
            let pi = Self.runtime(commands: commands)
            let provider = Self.legacyWorkspace
            var saved = AgentMCPSettings()
            saved.providers = [provider]
            let (model, defaults) = try Self.model(pi, settings: saved)
            #expect(model.settings.providers == [provider])

            // Pi lists the workspace's services with the sign-in it holds.
            #expect(try await model.services(of: provider).map(\.name) == ["system.ai.github", "system.ai.slack"])
            #expect(commands.withLock { $0 }.last == "/databricks-mcp-services https://example.cloud.databricks.com")
            try model.addServers(["system.ai.github": "github", "system.ai.slack": "work_slack"], to: provider)
            #expect(model.servers(of: provider).map(\.name) == ["github", "work_slack"])
            #expect(model.servers(of: provider).map(\.service) == ["system.ai.github", "system.ai.slack"])
            #expect(AgentMCPSettings.load(defaults: defaults) == model.settings)
            // A taken or invalid name saves nothing.
            #expect(throws: AgentMCPSettingsError.self) { try model.addServers(["system.ai.gmail": "github"], to: provider) }
            #expect(throws: AgentMCPSettingsError.self) { try model.addServers(["system.ai.gmail": "Mail-1"], to: provider) }
            #expect(model.settings.servers.count == 2)

            // Pi's auth.json holds the credential; Dahlia reads only which providers have one.
            let auth = try PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL).agentURL().appending(path: "auth.json")
            try Data(#"{"\#(provider.id)": {"type": "oauth", "access": "a", "refresh": "r", "expires": 1}}"#.utf8).write(to: auth)
            await model.refreshSignInState()
            #expect(model.signedInProviderIDs == [provider.id])

            // Removing a server keeps the sign-in; removing the workspace signs out and removes its servers.
            try model.remove(#require(model.settings.servers.first))
            #expect(!commands.withLock { $0 }.contains { $0.hasPrefix("/dahlia-logout") })
            await model.remove(provider)
            #expect(commands.withLock { $0 }.last == "/dahlia-logout example.cloud.databricks.com")
            #expect(model.settings == AgentMCPSettings())
            #expect(AgentMCPSettings.load(defaults: defaults) == AgentMCPSettings())
            #expect(model.errorMessage == nil)

            // Signing out of the account removes the sign-ins Pi kept for it.
            await pi.service.removeCredentials()
            #expect(!FileManager.default.fileExists(atPath: auth.path))
        }

        @Test
        func servicesTurnOnAndOffWithNamesOfTheirOwnAndTheLastListStays() async throws {
            let commands = OSAllocatedUnfairLock<[String]>(initialState: [])
            let (model, defaults) = try Self.model(Self.runtime(commands: commands))
            model.loadAccountProviders()
            let account = try #require(model.accountProviders.first)
            let workspace = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://example.cloud.databricks.com")))

            // The listing is kept, so a reopened model shows it before listing again.
            await model.refreshServices(of: account)
            #expect(model.listedServices(of: account) == ["system.ai.github", "system.ai.slack"])
            #expect(AgentMCPSettings.load(defaults: defaults).listedServices?["account.cloud.databricks.com"] == [
                "system.ai.github",
                "system.ai.slack",
            ])

            // The same service on two providers gets numbered names; turning one off removes only its server.
            try model.setService("system.ai.github", enabled: true, of: account)
            try model.setService("system.ai.github", enabled: true, of: workspace)
            #expect(model.settings.servers.map(\.name) == ["github", "github_2"])
            try model.setService("system.ai.github", enabled: false, of: account)
            #expect(model.settings.servers.map(\.name) == ["github_2"])
            // The account's own workspace leaves with its last server.
            #expect(!model.settings.providers.contains { $0.isAccount })

            #expect(AgentMCPSettings.load(defaults: defaults).servers.map(\.name) == ["github_2"])
            // A registered service stays listed even if the gateway stops offering it.
            #expect(model.listedServices(of: workspace) == ["system.ai.github"])
        }

        @Test
        func commentsPersistAndFailedRefreshKeepsTheLastDescription() async throws {
            let (model, defaults) = try Self.model(Self.runtime(commands: OSAllocatedUnfairLock(initialState: [])))
            model.loadAccountProviders()
            let provider = try #require(model.accountProviders.first)
            await model.refreshServices(of: provider)
            #expect(model.comment(for: "system.ai.github", of: provider) == "Search repositories")
            #expect(model.comment(for: "system.ai.slack", of: provider) == nil)
            #expect(AgentMCPSettings.load(defaults: defaults)
                .serviceComments?[provider.id]?["system.ai.github"] == "Search repositories")

            let failing = AgentMCPSettingsModel(
                service: Self.runtime(services: nil, commands: OSAllocatedUnfairLock(initialState: [])).service,
                defaults: defaults
            )
            await failing.refreshServices(of: provider)
            #expect(failing.listingErrors[provider.id] != nil)
            #expect(failing.comment(for: "system.ai.github", of: provider) == "Search repositories")
        }

        @Test
        func failedIndividualMetadataKeepsCommentButSuccessfulEmptyReadClearsIt() async throws {
            let response = OSAllocatedUnfairLock(initialState: AgentMCPService(name: "main.default.notion", comment: "Search Notion pages"))
            let pi = TestPiRuntime { _ in
                TestPiTransport { _ in
                    guard let data = try? JSONEncoder().encode([response.withLock { $0 }]) else {
                        Issue.record("Could not encode the mock service response")
                        return []
                    }
                    return [TestPiTransport.notify("databricks:mcp_services \(String(decoding: data, as: UTF8.self))")]
                }
            }
            let (model, defaults) = try Self.model(pi)
            model.loadAccountProviders()
            let provider = try #require(model.accountProviders.first)
            try model.addService("main.default.notion", to: provider)
            await model.refreshServices(of: provider)
            response.withLock { $0 = AgentMCPService(name: "main.default.notion", metadataUnavailable: true) }
            await model.refreshServices(of: provider)
            #expect(model.comment(for: "main.default.notion", of: provider) == "Search Notion pages")
            #expect(AgentMCPSettings.load(defaults: defaults)
                .serviceComments?[provider.id]?["main.default.notion"] == "Search Notion pages")
            response.withLock { $0 = AgentMCPService(name: "main.default.notion") }
            await model.refreshServices(of: provider)
            #expect(model.comment(for: "main.default.notion", of: provider) == nil)
        }

        @Test
        func loginCompletionDuringListingCoalescesARequiredFollowUp() async throws {
            let first = TestPiTransport()
            let launches = OSAllocatedUnfairLock(initialState: 0)
            let pi = TestPiRuntime { _ in
                let index = launches.withLock { value in defer { value += 1 }
                    return value
                }
                if index == 0 { return first }
                return TestPiTransport { command in
                    let message = command["message"]?.stringValue ?? ""
                    if message.hasPrefix("/databricks-connection-login") {
                        return [
                            TestPiTransport.notify("databricks:connection_auth_url https://example.cloud.databricks.com/oidc/v1/authorize"),
                            TestPiTransport.notify("databricks:connection_login_succeeded"),
                        ]
                    }
                    if message.hasPrefix("/databricks-mcp-services") {
                        return [TestPiTransport.notify(#"databricks:mcp_services [{"name":"system.ai.github","signInState":"signedIn"}]"#)]
                    }
                    return TestPiTransport.acknowledge(command)
                }
            }
            let (model, _) = try Self.model(pi)
            model.loadAccountProviders()
            let provider = try #require(model.accountProviders.first)
            try model.setService("system.ai.github", enabled: true, of: provider)
            let listing = Task { await model.refreshServices(of: provider) }
            _ = await first.command { $0["message"]?.stringValue?.hasPrefix("/databricks-mcp-services") == true }
            try await model.signInToService("system.ai.github", of: provider)
            // More requests while the original read is pending still need only one fresh read.
            await model.refreshServices(of: provider)
            await first.emit(TestPiTransport.notify(#"databricks:mcp_services [{"name":"system.ai.github","signInState":"signInRequired"}]"#))
            await listing.value
            #expect(model.signInState(for: "system.ai.github", of: provider) == .signedIn)
            #expect(launches.withLock { $0 } == 3) // initial listing, login, follow-up listing
            #expect(model.listingProviderIDs.isEmpty)
        }

        @Test
        func cancellationDropsQueuedRefreshAndAllowsRetry() async throws {
            let first = TestPiTransport()
            let launches = OSAllocatedUnfairLock(initialState: 0)
            let pi = TestPiRuntime { _ in
                let index = launches.withLock { value in defer { value += 1 }
                    return value
                }
                if index == 0 { return first }
                return TestPiTransport { command in
                    if command["message"]?.stringValue?.hasPrefix("/databricks-mcp-services") == true {
                        return [TestPiTransport.notify(#"databricks:mcp_services [{"name":"system.ai.github","signInState":"signedIn"}]"#)]
                    }
                    return TestPiTransport.acknowledge(command)
                }
            }
            let (model, _) = try Self.model(pi)
            model.loadAccountProviders()
            let provider = try #require(model.accountProviders.first)
            try model.setService("system.ai.github", enabled: true, of: provider)
            let listing = Task { await model.refreshServices(of: provider) }
            _ = await first.command { $0["message"]?.stringValue?.hasPrefix("/databricks-mcp-services") == true }
            await model.refreshServices(of: provider)
            listing.cancel()
            await listing.value
            #expect(launches.withLock { $0 } == 1)
            #expect(model.listingProviderIDs.isEmpty)
            await model.refreshServices(of: provider)
            #expect(model.signInState(for: "system.ai.github", of: provider) == .signedIn)
            #expect(launches.withLock { $0 } == 2)
        }

        @Test
        func databricksToolsNeedNoAdditionalSignInOrCredentialChecks() async throws {
            let commands = OSAllocatedUnfairLock<[String]>(initialState: [])
            let (model, _) = try Self.model(Self.runtime(commands: commands))
            let provider = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://example.cloud.databricks.com")))
            let services = ["system.ai.dbsql", "system.ai.sandbox", "system.ai.genie_one_mcp", "system.ai.web_search"]
            for service in services {
                #expect(!AgentMCPService.requiresUserSignIn(service))
                try model.setService(service, enabled: true, of: provider)
            }
            await model.refreshServices(of: provider)
            #expect(commands.withLock { $0 }.last == "/databricks-mcp-services https://example.cloud.databricks.com")
            #expect(AgentMCPService.requiresUserSignIn("system.ai.atlassian"))
            try model.setService("system.ai.atlassian", enabled: true, of: provider)
            await model.refreshServices(of: provider)
            #expect(commands.withLock { $0 }.last == "/databricks-mcp-services https://example.cloud.databricks.com --enabled system.ai.atlassian")
        }

        @Test
        func credentialStatesAreNotPersistedAndFailedRefreshClearsThem() async throws {
            let fail = OSAllocatedUnfairLock(initialState: false)
            let listing = #"""
            databricks:mcp_services [
              {"name":"system.ai.github","signInState":"signedIn"},
              {"name":"system.ai.slack","signInState":"signInRequired"},
              {"name":"system.ai.gmail","signInState":"unknown"}
            ]
            """#
            let pi = TestPiRuntime { _ in
                TestPiTransport { _ in
                    [TestPiTransport.notify(fail.withLock { $0 }
                            ? "databricks:mcp_services_failed unavailable"
                            : listing)]
                }
            }
            let (model, defaults) = try Self.model(pi)
            model.loadAccountProviders()
            let provider = try #require(model.accountProviders.first)
            try model.setService("system.ai.github", enabled: true, of: provider)
            try model.setService("system.ai.slack", enabled: true, of: provider)
            await model.refreshServices(of: provider)
            #expect(model.signInState(for: "system.ai.github", of: provider) == .signedIn)
            #expect(model.signInState(for: "system.ai.slack", of: provider) == .signInRequired)
            #expect(model.signInState(for: "system.ai.gmail", of: provider) == .unknown)
            let other = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://other.example.com")))
            #expect(model.signInState(for: "system.ai.github", of: other) == .unknown)
            let reopened = AgentMCPSettingsModel(service: pi.service, defaults: defaults)
            #expect(reopened.signInState(for: "system.ai.github", of: provider) == .unknown)
            fail.withLock { $0 = true }
            await model.refreshServices(of: provider)
            #expect(model.signInState(for: "system.ai.github", of: provider) == .unknown)
            #expect(model.listedServices(of: provider).contains("system.ai.github"))
        }

        @Test
        func directRegistrationValidatesPersistsAndCanBeDisabled() async throws {
            let commands = OSAllocatedUnfairLock(initialState: [String]())
            let pi = Self.runtime(commands: commands)
            let (model, defaults) = try Self.model(pi)
            model.loadAccountProviders()
            let provider = try #require(model.accountProviders.first)
            for invalid in [
                "notion",
                "default.notion",
                "main..notion",
                "main.default.notion.extra",
                "main.default.no tion",
                "main.default.notion --provider other",
            ] {
                #expect(throws: AgentMCPSettingsError.self) { try model.addService(invalid, to: provider) }
            }
            #expect(model.settings.servers.isEmpty)
            try model.addService(" main.default.notion\n", to: provider)
            try model.addService("main.default.notion", to: provider)
            try model.addService("other.default.notion", to: provider)
            try model.addService("system.ai.unlisted", to: provider)
            #expect(model.servers(of: provider).map(\.name) == ["notion", "notion_2", "unlisted"])
            #expect(AgentMCPSettings.load(defaults: defaults).servers == model.settings.servers)
            await model.refreshServices(of: provider)
            #expect(commands.withLock { $0 }.contains { $0.contains("--enabled main.default.notion,other.default.notion") })
            try model.setService("main.default.notion", enabled: false, of: provider)
            await model.refreshServices(of: provider)
            #expect(model.listedServices(of: provider).contains("main.default.notion"))
            #expect(!model.servers(of: provider).contains { $0.service == "main.default.notion" })
            #expect(model.settings.piServers["notion"] == nil)
            try model.setService("system.ai.unlisted", enabled: false, of: provider)
            await model.refreshServices(of: provider)
            let reopened = AgentMCPSettingsModel(service: pi.service, defaults: defaults)
            #expect(reopened.listedServices(of: provider).contains("system.ai.unlisted"))
            await model.remove(provider)
            #expect(model.settings.manualServices?[provider.id] == nil)
        }

        @Test
        func aServiceTakingAnotherServersNameReplacesItOrTakesAnAlias() throws {
            let (model, defaults) = try Self.model(Self.runtime(commands: OSAllocatedUnfairLock(initialState: [])))
            let first = Self.legacyWorkspace
            let second = AgentMCPProvider(workspaceURL: URL(string: "https://second.cloud.databricks.com")!)
            try model.setService("system.ai.github", enabled: true, of: first)
            let original = try #require(model.servers(of: first).first)
            let tool = "mcp__github__search"
            let oldGrants = Set(AgentMCPSettings.scheduledToolGrants(
                [tool], connections: model.settings.mcpConnectionIDs, servers: model.settings.scheduledServers
            ))
            #expect(model.settings.allowsScheduledTool(tool, grants: oldGrants))
            #expect(!model.settings.allowsScheduledTool(tool, grants: [tool]))
            #expect(model.conflictingServer(for: "system.ai.github", of: first) == nil)
            #expect(model.conflictingServer(for: "main.default.github", of: second) == original)
            #expect(model.conflictingServer(for: "system.ai.slack", of: second) == nil)

            try model.enableService("system.ai.github", of: second, name: "github_work")
            #expect(model.settings.servers.map(\.name).sorted() == ["github", "github_work"])
            #expect(throws: AgentMCPSettingsError.self) { try model.enableService("system.ai.slack", of: second, name: "github") }

            try model.setService("system.ai.github", enabled: false, of: second)
            try model.enableService("system.ai.github", of: second, replacing: original)
            #expect(model.servers(of: first).isEmpty)
            let replacement = try #require(model.servers(of: second).first)
            #expect(replacement.name == "github")
            #expect(replacement.id != original.id) // Durable grants bind the registration, so they do not carry over.
            #expect(!model.settings.allowsScheduledTool(tool, grants: oldGrants))
            let renewed = Set(AgentMCPSettings.scheduledToolGrants(
                [tool], connections: model.settings.mcpConnectionIDs, servers: model.settings.scheduledServers
            ))
            #expect(model.settings.allowsScheduledTool(tool, grants: renewed))
            #expect(AgentMCPSettings.load(defaults: defaults).servers.map(\.name) == ["github"])
        }

        @Test
        func replacingADirectServerKeepsItOffUnderAnotherName() throws {
            let (model, _) = try Self.model(Self.runtime(commands: OSAllocatedUnfairLock(initialState: [])))
            try model.saveDirectServer(name: "slack", .init(command: "slack-mcp"))
            let direct = try #require(model.directServers.first)
            let tool = "mcp__slack__search"
            let oldGrants = Set(AgentMCPSettings.scheduledToolGrants(
                [tool], connections: model.settings.mcpConnectionIDs, servers: model.settings.scheduledServers
            ))
            #expect(model.settings.allowsScheduledTool(tool, grants: oldGrants))
            #expect(model.conflictingServer(for: "system.ai.slack", of: Self.legacyWorkspace) == direct)
            try model.enableService("system.ai.slack", of: Self.legacyWorkspace, replacing: direct)
            let kept = try #require(model.directServers.first)
            #expect(kept.name == "slack_2")
            #expect(kept.direct?.isEnabled == false)
            #expect(kept.direct?.command == "slack-mcp")
            #expect(model.servers(of: Self.legacyWorkspace).map(\.name) == ["slack"])
            #expect(!model.settings.allowsScheduledTool(tool, grants: oldGrants))
            #expect(!model.settings.allowsScheduledTool(tool, grants: [tool]))
            let renewed = Set(AgentMCPSettings.scheduledToolGrants(
                [tool], connections: model.settings.mcpConnectionIDs, servers: model.settings.scheduledServers
            ))
            #expect(model.settings.allowsScheduledTool(tool, grants: renewed))
        }

        @Test
        func retiredLightpandaRegistrationDoesNotLaunch() throws {
            let (model, defaults) = try Self.model(Self.runtime(commands: OSAllocatedUnfairLock(initialState: [])))
            var settings = model.settings
            settings.servers.append(AgentMCPServer(id: .v7(), name: "lightpanda", providerID: nil, service: "lightpanda"))
            #expect(settings.piServers.isEmpty)
            settings.save(defaults: defaults)
            #expect(AgentMCPSettings.load(defaults: defaults).servers.isEmpty)
        }

        @Test
        func newServerNamesCannotRepeatUnderscores() {
            // `mcp__mail__work__read` would match both `mail` and `mail__work`.
            let settings = AgentMCPSettings()
            #expect(settings.nameError("mail__work") != nil)
            #expect(settings.nameError("mail_work") == nil)
            #expect(settings.defaultName(for: "main.default.foo__-bar") == "foo_bar")
            #expect(settings.defaultName(for: "main.default.foo-", taken: ["foo_"]) == "foo_2")
            #expect(settings.defaultName(for: "main.default.-", taken: ["_"]) == "_2")
        }

        @Test(arguments: ["mail__work", "mail_"], [false, true])
        func scheduledToolsRejectOverlappingServerNames(other: String, gateway: Bool) throws {
            let provider = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://example.com")))
            let settings = AgentMCPSettings(providers: [provider], servers: [
                .init(id: .v7(), name: "mail", providerID: nil, service: "mail", direct: .init(command: "mail-mcp")),
                .init(
                    id: .v7(),
                    name: other,
                    providerID: gateway ? provider.id : nil,
                    service: other,
                    direct: gateway ? nil : .init(command: "work-mcp")
                ),
            ])
            let tool = "mcp__\(other)__read"
            let grants = AgentMCPSettings.scheduledToolGrants([tool], connections: settings.mcpConnectionIDs, servers: settings.scheduledServers)
            #expect(grants.isEmpty)
            #expect(AgentMCPSettings.scheduledServer(for: tool, servers: settings.scheduledServers) == nil)
            let stale = Set([tool] + settings.mcpConnectionIDs.values.map { "connection|\(tool)|\($0)" })
            #expect(!settings.allowsScheduledTool(tool, grants: stale))
            #expect(AgentMCPSettings.scheduledServer(for: "mcp__mail__write", servers: settings.scheduledServers) == "mail")
            #expect(settings.piServers.count == 2) // Legacy registration data is retained.
        }

        @Test
        func webWorkerNamespaceCannotBeOverriddenByConfiguredServices() throws {
            let provider = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://example.cloud.databricks.com")))
            var settings = AgentMCPSettings()
            settings.providers = [provider]
            #expect(settings.nameError(AgentWebAccessSettings.serverName) != nil)
            settings.servers = [.init(id: .v7(), name: AgentWebAccessSettings.serverName, providerID: provider.id, service: "system.ai.github")]
            #expect(settings.piServers.isEmpty)
            #expect(settings.servers.count == 1)
        }

        @Test
        func oldSettingsDecodeWithoutLosingRegisteredServers() throws {
            let id = UUID()
            let data = Data("""
            {"providers":[],"servers":[{"id":"\(id)","name":"github","providerID":"workspace.example.com","service":"system.ai.github"}],
             "listedServices":{"workspace.example.com":["system.ai.github"]}}
            """.utf8)
            let settings = try JSONDecoder().decode(AgentMCPSettings.self, from: data)
            #expect(settings.servers.first?.id == id)
            #expect(settings.listedServices?["workspace.example.com"] == ["system.ai.github"])
            #expect(settings.serviceComments == nil)
            let migrationSuite = "AgentMCPSettingsMigration.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: migrationSuite))
            defer { defaults.removePersistentDomain(forName: migrationSuite) }
            var legacy = settings
            legacy.listedServices?["workspace.example.com"]?.append("main.default.notion")
            legacy.save(defaults: defaults)
            let migrated = AgentMCPSettings.load(defaults: defaults)
            #expect(migrated.manualServices?["workspace.example.com"] == ["main.default.notion"])
        }

        @Test
        func aServicesOwnSignInOpensInTheBrowser() async throws {
            let commands = OSAllocatedUnfairLock<[String]>(initialState: [])
            let urlOpener = TestCodexLoginURLOpener()
            let (model, _) = try Self.model(Self.runtime(commands: commands), urlOpener: urlOpener)
            let provider = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://example.cloud.databricks.com")))

            try model.setService("system.ai.github", enabled: true, of: provider)
            #expect(model.signInState(for: "system.ai.github", of: provider) == .unknown)
            try await model.signInToService("system.ai.github", of: provider)
            #expect(commands.withLock { $0 } == [
                "/databricks-connection-login https://example.cloud.databricks.com system.ai.github",
                "/databricks-mcp-services https://example.cloud.databricks.com --enabled system.ai.github",
            ])
            #expect(model.signInState(for: "system.ai.github", of: provider) == .signedIn)
            #expect(urlOpener.openedURLs == [URL(string: "https://example.cloud.databricks.com/oidc/v1/authorize")])
        }

        @Test
        func listingWithoutASignInAsksForOne() async throws {
            let pi = Self.runtime(services: nil, commands: OSAllocatedUnfairLock(initialState: []))
            let (model, _) = try Self.model(pi)
            let provider = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://example.cloud.databricks.com")))

            await #expect(throws: PiRuntimeError.notLoggedIn) { try await model.services(of: provider) }
        }

        @Test
        func theAccountsOwnWorkspaceServesMCPsWithTheAccountsSignIn() async throws {
            let commands = OSAllocatedUnfairLock<[String]>(initialState: [])
            let pi = Self.runtime(commands: commands)
            let (model, defaults) = try Self.model(pi)

            // Adding it under Providers would make a second sign-in for the same workspace, even before the tab loads it.
            await #expect(throws: AgentMCPSettingsError.self) {
                _ = try await model.addWorkspace(workspaceURL: "https://account.cloud.databricks.com/ml/ai-gateway?o=1")
            }
            model.loadAccountProviders()
            let provider = try #require(model.selectableProviders.first)
            #expect(provider.isAccount && provider.id == "account.cloud.databricks.com" && model.isSignedIn(provider))
            #expect(provider.workspaceURL == URL(string: "https://account.cloud.databricks.com"))
            // Listing takes the account's bridged sign-in; nothing signs in.
            _ = try await model.services(of: provider)
            #expect(commands
                .withLock { $0 } == ["/databricks-mcp-services https://account.cloud.databricks.com --provider account.cloud.databricks.com"])

            try model.addServers(["system.ai.slack": "slack"], to: provider)
            #expect(AgentMCPSettings.load(defaults: defaults).piServers["slack"] == .object([
                "url": .string("https://account.cloud.databricks.com/ai-gateway/mcp-services/system.ai.slack"),
                "exposure": .string("direct"),
                "auth": .object(["provider": .string("account.cloud.databricks.com")]),
            ]))
            // Its last server takes the workspace with it, and nothing signs out.
            try model.remove(#require(model.settings.servers.first))
            #expect(model.settings == AgentMCPSettings())
            #expect(commands.withLock { $0 }.count == 1)
        }

        @Test
        func aDirectServerIsWrittenAsItsStdioOrHTTPEntryWhileOn() throws {
            let (model, defaults) = try Self.model(Self.runtime(commands: OSAllocatedUnfairLock(initialState: [])))
            let script = #"eval "$(/usr/libexec/path_helper -s)"; exec dbexec repo run mcp start-single slack"#
            // Empty rows are skipped; a value keeps its spaces and `=`.
            let env = try #require(AgentMCPDirectConfiguration.pairs([("DBEXEC_NO_CERT_REFRESH", "1"), ("", ""), (" A ", "b = c")]))
            #expect(env == ["DBEXEC_NO_CERT_REFRESH": "1", "A": "b = c"])
            #expect(AgentMCPDirectConfiguration.pairs([("", "value")]) == nil)
            #expect(AgentMCPDirectConfiguration.pairs([("A", "1"), ("A", "2")]) == nil)

            try model.saveDirectServer(name: "slack", .init(command: "/bin/bash", args: ["-c", script], env: env))
            try model.saveDirectServer(name: "docs", .init(transport: .http, url: "https://example.com/mcp", headers: ["X-Key": "${KEY}"]))
            let servers = AgentMCPSettings.load(defaults: defaults).piServers
            #expect(servers["slack"] == .object([
                "command": .string("/bin/bash"), "args": .array([.string("-c"), .string(script)]), "exposure": .string("direct"),
                "env": .object(["DBEXEC_NO_CERT_REFRESH": .string("1"), "A": .string("b = c")]),
            ]))
            #expect(servers["docs"] == .object([
                "url": .string("https://example.com/mcp"), "headers": .object(["X-Key": .string("${KEY}")]), "exposure": .string("direct"),
            ]))
            // A name is unique across gateway and direct servers, and an entry Pi cannot start is not saved.
            #expect(throws: AgentMCPSettingsError.self) { try model.saveDirectServer(name: "slack", .init(command: "x")) }
            #expect(throws: AgentMCPSettingsError.self) { try model.saveDirectServer(name: "other", .init(transport: .http, url: "file:///x")) }
            #expect(throws: AgentMCPSettingsError.self) { try model.saveDirectServer(name: "other", .init()) }

            // Off keeps the configuration but leaves mcp.json and grants; on brings both back.
            let slack = try #require(model.directServers.first)
            let grant = try #require(model.settings.connectionID(for: "slack"))
            model.setDirectServer(slack, enabled: false)
            #expect(model.settings.piServers["slack"] == nil && model.settings.connectionID(for: "slack") == nil)
            model.setDirectServer(slack, enabled: true)
            #expect(model.settings.connectionID(for: "slack") == grant)
            model.remove(slack)
            #expect(model.directServers.map(\.name) == ["docs"])
        }

        @Test
        func editingADirectConnectionRetiresItsSourceGrant() throws {
            let (model, defaults) = try Self.model(Self.runtime(commands: OSAllocatedUnfairLock(initialState: [])))
            let configurations: [AgentMCPDirectConfiguration] = [
                .init(command: "mcp", args: ["a b"], env: ["DATABASE_URL": "first"]),
                .init(command: "mcp", args: ["a b"], env: ["DATABASE_URL": "second"]),
                .init(command: "mcp", args: ["a", "b"], env: ["DATABASE_URL": "second"]),
                .init(transport: .http, url: "https://example.com/mcp", headers: ["X-Tenant": "first"]),
                .init(transport: .http, url: "https://example.com/mcp", headers: ["X-Tenant": "second"]),
            ]
            try model.saveDirectServer(name: "direct", configurations[0])
            for configuration in configurations.dropFirst() {
                let previous = try #require(model.directServers.first)
                let grant = try #require(model.settings.connectionID(for: previous.name))
                try model.saveDirectServer(name: previous.name, configuration, replacing: previous)
                let saved = AgentMCPSettings.load(defaults: defaults)
                #expect(saved.connectionID(for: previous.name) != grant)
                #expect(saved.serverName(for: grant) == nil)

                let current = try #require(model.directServers.first)
                let currentGrant = saved.connectionID(for: current.name)
                try model.saveDirectServer(name: current.name, configuration, replacing: current)
                #expect(model.settings.connectionID(for: current.name) == currentGrant)
            }
        }

        @Test
        func directDraftParsesOnlyItsSelectedTransport() throws {
            let http = try AgentMCPDirectConfiguration.parse(
                transport: .http, command: "", arguments: [], environment: [("", "unfinished")], url: "https://example.com/mcp", headers: [(
                    "X-Key",
                    "value"
                )]
            )
            #expect(http.error == nil && http.env.isEmpty && http.headers == ["X-Key": "value"])
            let stdio = try AgentMCPDirectConfiguration.parse(
                transport: .stdio, command: "/bin/bash", arguments: ["-c", "echo 'a b'"], environment: [("KEY", "value")], url: "", headers: [(
                    "",
                    "unfinished"
                )]
            )
            #expect(stdio.error == nil && stdio.args == ["-c", "echo 'a b'"] && stdio.headers.isEmpty)
            #expect(throws: AgentMCPSettingsError.self) {
                try AgentMCPDirectConfiguration.parse(
                    transport: .stdio, command: "mcp", arguments: [], environment: [("", "unfinished")], url: "", headers: []
                )
            }
            #expect(throws: AgentMCPSettingsError.self) {
                try AgentMCPDirectConfiguration.parse(
                    transport: .http, command: "", arguments: [], environment: [], url: "https://example.com", headers: [("", "unfinished")]
                )
            }
            for url in ["https:", "http:/mcp", "https:///", "file:///mcp"] {
                #expect(AgentMCPDirectConfiguration(transport: .http, url: url).error != nil)
            }
        }

        @Test
        func directJSONPreservesArgumentBoundariesAndConnectionFields() throws {
            let stdio = AgentMCPDirectConfiguration(command: "/bin/bash", args: ["-c", "a b", "", "first\nsecond"], env: ["KEY": "${VALUE}"])
            let http = AgentMCPDirectConfiguration(
                transport: .http,
                url: "https://example.com:65535/mcp",
                headers: ["Authorization": "Bearer ${TOKEN}"]
            )
            for configuration in [stdio, http] {
                let json = try configuration.jsonString()
                let plain = try AgentMCPDirectConfiguration.parseJSON(json)
                #expect(plain.name == nil && plain.configuration == configuration)
                for name in ["slack", "command", "url", "type"] {
                    for wrapped in ["{\"\(name)\":\(json)}", "{\"mcpServers\":{\"\(name)\":\(json)}}"] {
                        let parsed = try AgentMCPDirectConfiguration.parseJSON(wrapped)
                        #expect(parsed.name == name && parsed.configuration == configuration)
                    }
                }
            }
            let draft = try AgentMCPDirectConfiguration.parse(
                transport: .stdio, command: "mcp", arguments: stdio.args, environment: [], url: "", headers: []
            )
            #expect(draft.args == stdio.args)
            #expect(try AgentMCPDirectConfiguration.parseJSON(#"{"command":"mcp"}"#).configuration.transport == .stdio)
            #expect(try AgentMCPDirectConfiguration.parseJSON(#"{"url":"https://example.com"}"#).configuration.transport == .http)
        }

        @Test(arguments: [
            "[]", "{}", #"{"a":{"command":"a"},"b":{"command":"b"}}"#,
            #"{"mcpServers":{},"extra":true}"#, #"{"command":"mcp","args":"-c"}"#,
            #"{"command":"mcp","env":{"KEY":1}}"#, #"{"type":"sse","url":"https://example.com"}"#,
            #"{"command":"mcp","headers":{}}"#, #"{"url":"https://example.com","args":[]}"#,
            #"{"command":"mcp","auth":{}}"#, #"{"type":"stdio"}"#,
            #"{"command":"mcp","env":{"":"value"}}"#,
            #"{"url":"https://example.com","headers":{"X-Key":"a"," X-Key ":"b"}}"#,
            String(repeating: " ", count: 65537),
        ])
        func invalidDirectJSONIsRejected(_ json: String) {
            #expect(throws: AgentMCPSettingsError.self) { try AgentMCPDirectConfiguration.parseJSON(json) }
        }

        @Test
        func generatedDirectJSONFitsTheImportBudget() throws {
            let empty = AgentMCPDirectConfiguration(command: "mcp", args: [""])
            let argumentBytes = try 65536 - (empty.jsonString().utf8.count)
            let boundary = AgentMCPDirectConfiguration(command: "mcp", args: [String(repeating: "a", count: argumentBytes)])
            let json = try boundary.jsonString()
            #expect(json.utf8.count == 65536)
            #expect(try AgentMCPDirectConfiguration.parseJSON(json).configuration == boundary)
            for argument in [
                String(repeating: "a", count: argumentBytes + 1),
                String(repeating: "あ", count: argumentBytes / 3 + 1),
                String(repeating: "\n", count: argumentBytes / 2 + 1),
            ] {
                let oversized = AgentMCPDirectConfiguration(command: "mcp", args: [argument])
                #expect(throws: AgentMCPSettingsError.self) { try oversized.jsonString() }
            }
        }

        @Test
        func incompleteDirectJSONCanReturnToFormButCannotBeSaved() throws {
            let (model, _) = try Self.model(Self.runtime(commands: OSAllocatedUnfairLock(initialState: [])))
            for draft in [AgentMCPDirectConfiguration(), .init(transport: .http), .init(transport: .http, url: "https://example.com:99999")] {
                let parsed = try AgentMCPDirectConfiguration.parseJSON(draft.jsonString())
                #expect(parsed.configuration == draft)
                #expect(throws: AgentMCPSettingsError.self) { try model.saveDirectServer(name: "draft", parsed.configuration) }
            }
            #expect(model.directServers.isEmpty)
        }

        @Test(arguments: ["65536", "99999", "-1", "invalid"])
        func directHTTPRejectsInvalidPorts(_ port: String) {
            #expect(AgentMCPDirectConfiguration(transport: .http, url: "https://example.com:\(port)/mcp").error != nil)
        }

        @Test(arguments: ["0", "443", "65535"])
        func directHTTPAcceptsValidPorts(_ port: String) {
            #expect(AgentMCPDirectConfiguration(transport: .http, url: "https://example.com:\(port)/mcp").error == nil)
        }

        @Test
        func scheduledDirectToolsRequireTheirApprovedConnection() throws {
            let (model, _) = try Self.model(Self.runtime(commands: OSAllocatedUnfairLock(initialState: [])))
            try model.saveDirectServer(name: "mail", .init(command: "mcp", env: ["TENANT": "first"]))
            let name = "mcp__mail__read"
            let grants = Set(AgentMCPSettings.scheduledToolGrants(
                [name, "mcp__dahlia__get_meetings"],
                connections: model.settings.mcpConnectionIDs,
                servers: model.settings.scheduledServers
            ))
            #expect(model.settings.allowsScheduledTool(name, grants: grants))
            #expect(!model.settings.allowsScheduledTool(name, grants: [name]))
            #expect(model.settings.allowsScheduledTool("mcp__dahlia__get_meetings", grants: grants))
            let server = try #require(model.directServers.first)
            model.setDirectServer(server, enabled: false)
            #expect(!model.settings.allowsScheduledTool(name, grants: grants))
            model.setDirectServer(server, enabled: true)
            #expect(model.settings.allowsScheduledTool(name, grants: grants))
            try model.saveDirectServer(name: "mail", .init(command: "mcp", env: ["TENANT": "second"]), replacing: server)
            #expect(!model.settings.allowsScheduledTool(name, grants: grants))
            let edited = try #require(model.directServers.first)
            let renewed = Set(AgentMCPSettings.scheduledToolGrants(
                [name],
                connections: model.settings.mcpConnectionIDs,
                servers: model.settings.scheduledServers
            ))
            #expect(model.settings.allowsScheduledTool(name, grants: renewed))
            model.remove(edited)
            #expect(!model.settings.allowsScheduledTool(name, grants: renewed))
            try model.saveDirectServer(name: "mail", .init(command: "mcp", env: ["TENANT": "second"]))
            #expect(!model.settings.allowsScheduledTool(name, grants: renewed))
        }

        @Test
        func aWorkspaceIsRemovedEvenWhenPiCannotSignOut() async throws {
            let pi = Self.runtime(logoutSucceeds: false, commands: OSAllocatedUnfairLock(initialState: []))
            var saved = AgentMCPSettings()
            saved.providers = [Self.legacyWorkspace]
            let (model, defaults) = try Self.model(pi, settings: saved)
            let provider = Self.legacyWorkspace
            try model.addServers(["system.ai.github": "github"], to: provider)

            let agentURL = try PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL).agentURL()
            try PiProviderConfiguration.write([provider.id: .object(["models": .array([])])], agentURL: agentURL)
            let generation = PiRuntimeService.modelsGeneration.withLock { $0 }
            await model.remove(provider)
            // Its models.json entry goes with it, so Pi lists none of its models even with the credential kept.
            let written = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: agentURL.appending(path: "models.json")))
            #expect(written.objectValue?["providers"]?.objectValue?[provider.id] == nil)
            #expect(model.settings.providers.isEmpty && model.settings.servers.isEmpty)
            #expect(AgentMCPSettings.load(defaults: defaults).providers.isEmpty)
            #expect(model.errorMessage != nil)
            // The removed workspace's models leave the pickers even though Pi could not sign out.
            #expect(PiRuntimeService.modelsGeneration.withLock { $0 } > generation)
            #expect(!model.isBusy)
        }

        @Test
        func piExitingWhileListingIsReportedNotTakenForACancel() async throws {
            let transport = TestPiTransport()
            let pi = TestPiRuntime { _ in transport }
            let (model, _) = try Self.model(pi)
            let provider = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://example.cloud.databricks.com")))

            async let listing: Void = model.refreshServices(of: provider)
            _ = await transport.command { $0["message"]?.stringValue?.hasPrefix("/databricks-mcp-services") == true }
            await transport.close()
            await listing
            #expect(model.listingErrors[provider.id] as? PiRuntimeError == .processExited(nil))
        }

        @Test
        func servicesShowReadableNames() {
            #expect(AgentMCPServer.displayName(for: "system.ai.google_calendar") == "Google Calendar")
            #expect(AgentMCPServer.displayName(for: "system.ai.genie_one_mcp") == "Genie One")
            #expect(AgentMCPServer.displayName(for: "system.ai.dbsql") == "Databricks SQL")
            #expect(AgentMCPServer.displayName(for: "system.ai.sandbox") == "Databricks Sandbox")
            #expect(AgentMCPServer.displayName(for: "system.ai.github") == "GitHub")
            #expect(AgentMCPServer.displayName(for: "system.ai.microsoft_365") == "Microsoft 365")
        }

        @Test
        func aFailedSignInSavesNothing() async throws {
            struct Refused: Error {}
            let pi = Self.runtime(succeeds: false, commands: OSAllocatedUnfairLock(initialState: []))
            let (model, defaults) = try Self.model(pi) { _ in throw Refused() }

            await #expect(throws: Refused.self) {
                _ = try await model.addWorkspace(workspaceURL: "https://example.cloud.databricks.com")
            }
            // A host without a dot could not be told from Pi's own providers in chat, so it is refused before sign-in.
            await #expect(throws: AIConfigurationError.invalidDatabricksWorkspaceURL) {
                _ = try await model.addWorkspace(workspaceURL: "https://gateway")
            }
            #expect(model.settings == AgentMCPSettings())
            #expect(AgentMCPSettings.load(defaults: defaults) == AgentMCPSettings())
            #expect(!model.isBusy)
        }
    }
#endif
