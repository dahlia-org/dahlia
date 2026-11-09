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
            services: [String]? = ["system.ai.github", "system.ai.slack"],
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
            #expect(try await model.services(of: provider) == ["system.ai.github", "system.ai.slack"])
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
            model.remove(try #require(model.settings.servers.first))
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
            let workspace = AgentMCPProvider(workspaceURL: URL(string: "https://example.cloud.databricks.com")!)

            // The listing is kept, so a reopened model shows it before listing again.
            await model.refreshServices(of: account)
            #expect(model.listedServices(of: account) == ["system.ai.github", "system.ai.slack"])
            #expect(AgentMCPSettings.load(for: Self.account, defaults: defaults).listedServices?["databricks"] == ["system.ai.github", "system.ai.slack"])

            // The same service on two providers gets numbered names; turning one off removes only its server.
            try model.setService("system.ai.github", enabled: true, of: account)
            try model.setService("system.ai.github", enabled: true, of: workspace)
            #expect(model.settings.servers.map(\.name) == ["github", "github_2"])
            try model.setService("system.ai.github", enabled: false, of: account)
            #expect(model.settings.servers.map(\.name) == ["github_2"])
            // The account's own workspace leaves with its last server.
            #expect(!model.settings.providers.contains { $0.isAccount })

            let server = try #require(model.settings.servers.first)
            try model.rename(server, to: "work_github")
            #expect(model.settings.servers.map(\.name) == ["work_github"])
            // Keeping its own name is fine; a taken or invalid one is not.
            let renamed = try #require(model.settings.servers.first)
            try model.rename(renamed, to: "work_github")
            #expect(throws: AgentMCPSettingsError.self) { try model.rename(renamed, to: "dahlia") }
            #expect(throws: AgentMCPSettingsError.self) { try model.rename(renamed, to: "Work-GitHub") }
            #expect(AgentMCPSettings.load(for: Self.account, defaults: defaults).servers.map(\.name) == ["work_github"])
            // A registered service stays listed even if the gateway stops offering it.
            #expect(model.listedServices(of: workspace) == ["system.ai.github"])
        }

        @Test
        func aServicesOwnSignInOpensInTheBrowser() async throws {
            let commands = OSAllocatedUnfairLock<[String]>(initialState: [])
            let urlOpener = TestCodexLoginURLOpener()
            let (model, _) = try Self.model(Self.runtime(commands: commands), urlOpener: urlOpener)
            let provider = AgentMCPProvider(workspaceURL: URL(string: "https://example.cloud.databricks.com")!)

            try await model.signInToService("system.ai.github", of: provider)
            #expect(commands.withLock { $0 } == ["/databricks-connection-login https://example.cloud.databricks.com system.ai.github"])
            #expect(urlOpener.openedURLs == [URL(string: "https://example.cloud.databricks.com/oidc/v1/authorize")])
        }

        @Test
        func listingWithoutASignInAsksForOne() async throws {
            let pi = Self.runtime(services: nil, commands: OSAllocatedUnfairLock(initialState: []))
            let (model, _) = try Self.model(pi)
            let provider = AgentMCPProvider(workspaceURL: URL(string: "https://example.cloud.databricks.com")!)

            await #expect(throws: CodexAppServerError.notLoggedIn) { try await model.services(of: provider) }
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
            model.remove(try #require(model.settings.servers.first))
            #expect(model.settings == AgentMCPSettings())
            #expect(commands.withLock { $0 }.count == 1)
        }

        @Test
        func aWorkspaceIsRemovedEvenWhenPiCannotSignOut() async throws {
            let pi = Self.runtime(logoutSucceeds: false, commands: OSAllocatedUnfairLock(initialState: []))
            let (model, defaults) = try Self.model(pi)
            let provider = try await model.addWorkspace(workspaceURL: "https://example.cloud.databricks.com")
            try model.addServers(["system.ai.github": "github"], to: provider)

            await model.remove(provider)
            #expect(model.settings.providers.isEmpty && model.settings.servers.isEmpty)
            #expect(AgentMCPSettings.load(for: Self.account, defaults: defaults).providers.isEmpty)
            #expect(model.errorMessage != nil)
            #expect(!model.isBusy)
        }

        @Test
        func piExitingWhileListingIsReportedNotTakenForACancel() async throws {
            let transport = TestPiTransport()
            let pi = TestPiRuntime(provider: Self.account) { _ in transport }
            let (model, _) = try Self.model(pi)
            let provider = AgentMCPProvider(workspaceURL: URL(string: "https://example.cloud.databricks.com")!)

            async let listing: Void = model.refreshServices(of: provider)
            _ = await transport.command { $0["message"]?.stringValue?.hasPrefix("/databricks-mcp-services") == true }
            await transport.close()
            await listing
            #expect(model.listingErrors[provider.id] as? CodexAppServerError == .processExited(nil))
        }

        @Test
        func aFailedSignInSavesNothing() async throws {
            let pi = Self.runtime(succeeds: false, commands: OSAllocatedUnfairLock(initialState: []))
            let (model, defaults) = try Self.model(pi)

            await #expect(throws: CodexAppServerError.self) {
                _ = try await model.addWorkspace(workspaceURL: "https://example.cloud.databricks.com")
            }
            #expect(model.settings == AgentMCPSettings())
            #expect(AgentMCPSettings.load(for: Self.account, defaults: defaults) == AgentMCPSettings())
            #expect(!model.isBusy)
        }
    }
#endif
