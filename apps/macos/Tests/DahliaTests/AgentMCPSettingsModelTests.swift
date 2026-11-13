import DahliaRuntimeSupport
import Foundation
import os
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct AgentMCPSettingsModelTests {
        private static let account = CodexRuntimeProvider.databricks(connectionID: UUID())

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
            TestPiRuntime(provider: account) { _ in
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

        private static func model(_ pi: TestPiRuntime, urlOpener: TestCodexLoginURLOpener = TestCodexLoginURLOpener()) throws
            -> (AgentMCPSettingsModel, UserDefaults) {
            let defaults = try #require(UserDefaults(suiteName: "AgentMCPSettingsModelTests.\(UUID())"))
            let model = AgentMCPSettingsModel(
                account: account, service: pi.service, urlOpener: urlOpener, defaults: defaults,
                accountWorkspaceURL: { _ in URL(string: "https://account.cloud.databricks.com")! }
            )
            return (model, defaults)
        }

        @Test
        func aWorkspaceSignsInOnceAndItsChosenServicesShareTheSignIn() async throws {
            let commands = OSAllocatedUnfairLock<[String]>(initialState: [])
            let pi = Self.runtime(commands: commands)
            let urlOpener = TestCodexLoginURLOpener()
            let (model, defaults) = try Self.model(pi, urlOpener: urlOpener)

            let provider = try await model.addWorkspace(workspaceURL: "https://Example.cloud.databricks.com/")
            // The ID follows the workspace URL; Settings shows its host.
            #expect(provider.id == "example.cloud.databricks.com")
            #expect(provider.host == "example.cloud.databricks.com")
            #expect(commands.withLock { $0 } == ["/databricks-login https://example.cloud.databricks.com"])
            #expect(urlOpener.openedURLs == [URL(string: "https://example.cloud.databricks.com/oidc/v1/authorize")])
            #expect(pi.launches.all.allSatisfy { $0.mode == .control && $0.environment.isEmpty })
            // Adding the same workspace again signs in again and keeps one provider.
            #expect(try await model.addWorkspace(workspaceURL: "https://example.cloud.databricks.com") == provider)
            #expect(commands.withLock { $0 }.count == 2)
            #expect(model.settings.providers == [provider])

            // Pi lists the workspace's services with the sign-in it holds.
            #expect(try await model.services(of: provider).map(\.name) == ["system.ai.github", "system.ai.slack"])
            #expect(commands.withLock { $0 }.last == "/databricks-mcp-services https://example.cloud.databricks.com")
            try model.addServers(["system.ai.github": "github", "system.ai.slack": "work_slack"], to: provider)
            #expect(model.servers(of: provider).map(\.name) == ["github", "work_slack"])
            #expect(model.servers(of: provider).map(\.service) == ["system.ai.github", "system.ai.slack"])
            #expect(AgentMCPSettings.load(for: Self.account, defaults: defaults) == model.settings)
            // A taken or invalid name saves nothing.
            #expect(throws: AgentMCPSettingsError.self) { try model.addServers(["system.ai.gmail": "github"], to: provider) }
            #expect(throws: AgentMCPSettingsError.self) { try model.addServers(["system.ai.gmail": "Mail-1"], to: provider) }
            #expect(model.settings.servers.count == 2)

            // Pi's auth.json holds the credential; Dahlia reads only which providers have one.
            let auth = try PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL).agentURL(for: Self.account).appending(path: "auth.json")
            try Data(#"{"\#(provider.id)": {"type": "oauth", "access": "a", "refresh": "r", "expires": 1}}"#.utf8).write(to: auth)
            await model.refreshSignInState()
            #expect(model.signedInProviderIDs == [provider.id])

            // Removing a server keeps the sign-in; removing the workspace signs out and removes its servers.
            try model.remove(#require(model.settings.servers.first))
            #expect(!commands.withLock { $0 }.contains { $0.hasPrefix("/dahlia-logout") })
            await model.remove(provider)
            #expect(commands.withLock { $0 }.last == "/dahlia-logout example.cloud.databricks.com")
            #expect(model.settings == AgentMCPSettings())
            #expect(AgentMCPSettings.load(for: Self.account, defaults: defaults) == AgentMCPSettings())
            #expect(model.errorMessage == nil)

            // Signing out of the account removes the sign-ins Pi kept for it.
            await pi.service.removeCredentials(of: Self.account)
            #expect(!FileManager.default.fileExists(atPath: auth.path))
        }

        @Test
        func servicesTurnOnAndOffWithNamesOfTheirOwnAndTheLastListStays() async throws {
            let commands = OSAllocatedUnfairLock<[String]>(initialState: [])
            let (model, defaults) = try Self.model(Self.runtime(commands: commands))
            await model.loadAccountProvider()
            let account = try #require(model.accountProvider)
            let workspace = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://example.cloud.databricks.com")))

            // The listing is kept, so a reopened model shows it before listing again.
            await model.refreshServices(of: account)
            #expect(model.listedServices(of: account) == ["system.ai.github", "system.ai.slack"])
            #expect(AgentMCPSettings.load(for: Self.account, defaults: defaults).listedServices?["databricks"] == [
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

            #expect(AgentMCPSettings.load(for: Self.account, defaults: defaults).servers.map(\.name) == ["github_2"])
            // A registered service stays listed even if the gateway stops offering it.
            #expect(model.listedServices(of: workspace) == ["system.ai.github"])
        }

        @Test
        func commentsPersistAndFailedRefreshKeepsTheLastDescription() async throws {
            let (model, defaults) = try Self.model(Self.runtime(commands: OSAllocatedUnfairLock(initialState: [])))
            await model.loadAccountProvider()
            let provider = try #require(model.accountProvider)
            await model.refreshServices(of: provider)
            #expect(model.comment(for: "system.ai.github", of: provider) == "Search repositories")
            #expect(model.comment(for: "system.ai.slack", of: provider) == nil)
            #expect(AgentMCPSettings.load(for: Self.account, defaults: defaults)
                .serviceComments?[provider.id]?["system.ai.github"] == "Search repositories")

            let failing = AgentMCPSettingsModel(
                account: Self.account,
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
            let pi = TestPiRuntime(provider: Self.account) { _ in
                TestPiTransport { _ in
                    guard let data = try? JSONEncoder().encode([response.withLock { $0 }]) else {
                        Issue.record("Could not encode the mock service response")
                        return []
                    }
                    return [TestPiTransport.notify("databricks:mcp_services \(String(decoding: data, as: UTF8.self))")]
                }
            }
            let (model, defaults) = try Self.model(pi)
            await model.loadAccountProvider()
            let provider = try #require(model.accountProvider)
            try model.addService("main.default.notion", to: provider)
            await model.refreshServices(of: provider)
            response.withLock { $0 = AgentMCPService(name: "main.default.notion", metadataUnavailable: true) }
            await model.refreshServices(of: provider)
            #expect(model.comment(for: "main.default.notion", of: provider) == "Search Notion pages")
            #expect(AgentMCPSettings.load(for: Self.account, defaults: defaults)
                .serviceComments?[provider.id]?["main.default.notion"] == "Search Notion pages")
            response.withLock { $0 = AgentMCPService(name: "main.default.notion") }
            await model.refreshServices(of: provider)
            #expect(model.comment(for: "main.default.notion", of: provider) == nil)
        }

        @Test
        func loginCompletionDuringListingCoalescesARequiredFollowUp() async throws {
            let first = TestPiTransport()
            let launches = OSAllocatedUnfairLock(initialState: 0)
            let pi = TestPiRuntime(provider: Self.account) { _ in
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
            await model.loadAccountProvider()
            let provider = try #require(model.accountProvider)
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
            let pi = TestPiRuntime(provider: Self.account) { _ in
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
            await model.loadAccountProvider()
            let provider = try #require(model.accountProvider)
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
            let pi = TestPiRuntime(provider: Self.account) { _ in
                TestPiTransport { _ in
                    [TestPiTransport.notify(fail.withLock { $0 }
                            ? "databricks:mcp_services_failed unavailable"
                            : listing)]
                }
            }
            let (model, defaults) = try Self.model(pi)
            await model.loadAccountProvider()
            let provider = try #require(model.accountProvider)
            try model.setService("system.ai.github", enabled: true, of: provider)
            try model.setService("system.ai.slack", enabled: true, of: provider)
            await model.refreshServices(of: provider)
            #expect(model.signInState(for: "system.ai.github", of: provider) == .signedIn)
            #expect(model.signInState(for: "system.ai.slack", of: provider) == .signInRequired)
            #expect(model.signInState(for: "system.ai.gmail", of: provider) == .unknown)
            let other = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://other.example.com")))
            #expect(model.signInState(for: "system.ai.github", of: other) == .unknown)
            let reopened = AgentMCPSettingsModel(account: Self.account, service: pi.service, defaults: defaults)
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
            await model.loadAccountProvider()
            let provider = try #require(model.accountProvider)
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
            #expect(AgentMCPSettings.load(for: Self.account, defaults: defaults).servers == model.settings.servers)
            await model.refreshServices(of: provider)
            #expect(commands.withLock { $0 }.contains { $0.contains("--enabled main.default.notion,other.default.notion") })
            try model.setService("main.default.notion", enabled: false, of: provider)
            await model.refreshServices(of: provider)
            #expect(model.listedServices(of: provider).contains("main.default.notion"))
            #expect(!model.servers(of: provider).contains { $0.service == "main.default.notion" })
            #expect(model.settings.piServers["notion"] == nil)
            try model.setService("system.ai.unlisted", enabled: false, of: provider)
            await model.refreshServices(of: provider)
            let reopened = AgentMCPSettingsModel(account: Self.account, service: pi.service, defaults: defaults)
            #expect(reopened.listedServices(of: provider).contains("system.ai.unlisted"))
            await model.remove(provider)
            #expect(model.settings.manualServices?[provider.id] == nil)
        }

        @Test
        func retiredLightpandaRegistrationDoesNotLaunch() throws {
            let (model, defaults) = try Self.model(Self.runtime(commands: OSAllocatedUnfairLock(initialState: [])))
            var settings = model.settings
            settings.servers.append(AgentMCPServer(id: .v7(), name: "lightpanda", providerID: nil, service: "lightpanda"))
            #expect(settings.piServers.isEmpty)
            settings.save(for: Self.account, defaults: defaults)
            #expect(AgentMCPSettings.load(for: Self.account, defaults: defaults).servers.isEmpty)
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
            legacy.save(for: Self.account, defaults: defaults)
            let migrated = AgentMCPSettings.load(for: Self.account, defaults: defaults)
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
            await model.loadAccountProvider()
            let provider = try #require(model.selectableProviders.first)
            #expect(provider.isAccount && provider.id == "databricks" && model.isSignedIn(provider))
            #expect(provider.workspaceURL == URL(string: "https://account.cloud.databricks.com"))
            // Listing takes the account's bridged sign-in; nothing signs in.
            _ = try await model.services(of: provider)
            #expect(commands.withLock { $0 } == ["/databricks-mcp-services https://account.cloud.databricks.com --provider databricks"])

            try model.addServers(["system.ai.slack": "slack"], to: provider)
            #expect(AgentMCPSettings.load(for: Self.account, defaults: defaults).piServers["slack"] == .object([
                "url": .string("https://account.cloud.databricks.com/ai-gateway/mcp-services/system.ai.slack"),
                "exposure": .string("direct"),
                "auth": .object(["provider": .string("databricks")]),
            ]))
            // Its last server takes the workspace with it, and nothing signs out.
            try model.remove(#require(model.settings.servers.first))
            #expect(model.settings == AgentMCPSettings())
            #expect(commands.withLock { $0 }.count == 1)
        }

        @Test
        func aWorkspaceIsRemovedEvenWhenPiCannotSignOut() async throws {
            let pi = Self.runtime(logoutSucceeds: false, commands: OSAllocatedUnfairLock(initialState: []))
            let (model, defaults) = try Self.model(pi)
            let provider = try await model.addWorkspace(workspaceURL: "https://example.cloud.databricks.com")
            try model.addServers(["system.ai.github": "github"], to: provider)

            let agentURL = try PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL).agentURL(for: Self.account)
            try PiProviderConfiguration.write([provider.id: .object(["models": .array([])])], agentURL: agentURL)
            let generation = PiRuntimeService.modelsGeneration.withLock { $0 }
            await model.remove(provider)
            // Its models.json entry goes with it, so Pi lists none of its models even with the credential kept.
            let written = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: agentURL.appending(path: "models.json")))
            #expect(written.objectValue?["providers"]?.objectValue?[provider.id] == nil)
            #expect(model.settings.providers.isEmpty && model.settings.servers.isEmpty)
            #expect(AgentMCPSettings.load(for: Self.account, defaults: defaults).providers.isEmpty)
            #expect(model.errorMessage != nil)
            // The removed workspace's models leave the pickers even though Pi could not sign out.
            #expect(PiRuntimeService.modelsGeneration.withLock { $0 } > generation)
            #expect(!model.isBusy)
        }

        @Test
        func piExitingWhileListingIsReportedNotTakenForACancel() async throws {
            let transport = TestPiTransport()
            let pi = TestPiRuntime(provider: Self.account) { _ in transport }
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
            let pi = Self.runtime(succeeds: false, commands: OSAllocatedUnfairLock(initialState: []))
            let (model, defaults) = try Self.model(pi)

            await #expect(throws: PiRuntimeError.self) {
                _ = try await model.addWorkspace(workspaceURL: "https://example.cloud.databricks.com")
            }
            // A host without a dot could not be told from Pi's own providers in chat, so it is refused before sign-in.
            await #expect(throws: AIConfigurationError.invalidDatabricksWorkspaceURL) {
                _ = try await model.addWorkspace(workspaceURL: "https://gateway")
            }
            #expect(model.settings == AgentMCPSettings())
            #expect(AgentMCPSettings.load(for: Self.account, defaults: defaults) == AgentMCPSettings())
            #expect(!model.isBusy)
        }
    }
#endif
