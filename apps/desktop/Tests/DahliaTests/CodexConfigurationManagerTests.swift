import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexConfigurationManagerTests {
        @Test
        func dahliaConfigurationUsesPrivateConnectionHomeAndDynamicTokenHelper() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-codex-config-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            let manager = CodexConfigurationManager(homeLocator: locator)
            let connectionID = UUID()
            let helperURL = URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/dahlia-mcp")

            #expect(try await manager.configureDahlia(
                connectionID: connectionID,
                origin: "https://cloud.example.com",
                helperURL: helperURL,
                runtimeProfile: .development
            ))

            let localHome = try locator.homeURL(connectionID: nil)
            let accountHome = try locator.homeURL(connectionID: connectionID)
            let configURL = accountHome.appending(path: "config.toml")
            let configuration = try String(contentsOf: configURL, encoding: .utf8)
            #expect(localHome != accountHome)
            #expect(configuration.contains(#"model_provider = "dahlia""#))
            #expect(configuration.contains(#"base_url = "https://cloud.example.com/api/v1""#))
            #expect(configuration.contains(#"command = "/Applications/Dahlia.app/Contents/Helpers/dahlia-mcp""#))
            #expect(configuration.contains("--connection-id"))
            #expect(configuration.contains(connectionID.uuidString))
            #expect(configuration.contains(#"--profile", "development""#))
            #expect(!configuration.localizedCaseInsensitiveContains("token ="))
            let homeAttributes = try FileManager.default.attributesOfItem(atPath: accountHome.path)
            let configAttributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
            #expect((homeAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            #expect((configAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }

        @Test
        func databricksConfigurationUsesSelectedCLIProfile() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-codex-config-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let manager = CodexConfigurationManager(
                homeLocator: ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            )
            let profile = try await databricksProfile(
                name: "Team's Profile",
                host: "https://dbc.example.com/"
            )

            #expect(try await manager.configureDatabricks(profile: profile))
            #expect(try await !manager.configureDatabricks(profile: profile))

            let configURL = try ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
                .homeURL()
                .appending(path: "config.toml")
            let configuration = try String(contentsOf: configURL, encoding: .utf8)
            #expect(configuration.contains(#"model_provider = "databricks""#))
            #expect(!configuration.contains("[profiles."))
            #expect(configuration.contains(#"base_url = "https://dbc.example.com/ai-gateway/codex/v1""#))
            #expect(configuration.contains(#"wire_api = "responses""#))
            #expect(configuration.contains(#"--profile 'Team'\"'\"'s Profile'"#))
            #expect(configuration.contains("/usr/bin/plutil -extract access_token raw -o - -"))
            #expect(!configuration.contains("jq"))
            #expect(configuration.contains("timeout_ms = 5000"))
            #expect(configuration.contains("refresh_interval_ms = 1800000"))
            #expect(configuration.contains(#"Databricks-Ai-Gateway-Request-Tags = "{\"source\": \"dahlia\"}""#))
            let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }

        @Test
        func providerConfigurationWritesOnlyToItsTargetHome() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-codex-target-home-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            let manager = CodexConfigurationManager(homeLocator: locator)
            let connectionID = UUID.v7()
            _ = try await manager.configureDahlia(
                connectionID: connectionID,
                origin: "https://cloud.example.com",
                helperURL: URL(filePath: "/Applications/Dahlia.app/Contents/Helpers/dahlia-mcp"),
                runtimeProfile: .production
            )
            _ = try await manager.configureDatabricks(
                profile: try await databricksProfile(name: "WORK", host: "https://dbc.example.com")
            )

            let accountConfigURL = try locator.homeURL(connectionID: connectionID).appending(path: "config.toml")
            let localConfigURL = try locator.homeURL(connectionID: nil).appending(path: "config.toml")
            #expect(try String(contentsOf: accountConfigURL, encoding: .utf8).contains(#"model_provider = "dahlia""#))
            #expect(try String(contentsOf: localConfigURL, encoding: .utf8).contains(#"model_provider = "databricks""#))

            _ = try await manager.configureChatGPTSubscription()
            #expect(try String(contentsOf: accountConfigURL, encoding: .utf8).contains(#"model_provider = "dahlia""#))
            #expect(try String(contentsOf: localConfigURL, encoding: .utf8).contains(#"model_provider = "openai""#))
        }

        @Test
        func chatGPTConfigurationPreservesDatabricksConfiguration() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-codex-config-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            let manager = CodexConfigurationManager(homeLocator: locator)
            let profile = try await databricksProfile(name: "DEFAULT", host: "https://dbc.example.com")
            _ = try await manager.configureDatabricks(profile: profile)
            let configURL = try locator.homeURL().appending(path: "config.toml")
            var originalConfiguration = try String(contentsOf: configURL, encoding: .utf8)
            originalConfiguration = originalConfiguration.replacingOccurrences(
                of: #"model_provider = "databricks""#,
                with: #"model_provider = "databricks" # selected by Dahlia"#
            )
            originalConfiguration += """

            [profiles.work]
            model_provider = "Databricks"
            """
            try Data(originalConfiguration.utf8).write(to: configURL)

            #expect(try await manager.configureChatGPTSubscription())
            #expect(try await !manager.configureChatGPTSubscription())
            let configuration = try String(contentsOf: configURL, encoding: .utf8)
            #expect(configuration.contains(#"model_provider = "openai" # selected by Dahlia"#))
            #expect(configuration.contains("[model_providers.databricks]"))
            #expect(configuration.contains(#"base_url = "https://dbc.example.com/ai-gateway/codex/v1""#))
            #expect(configuration.contains("""
            [profiles.work]
            model_provider = "Databricks"
            """))
        }

        @Test
        func chatGPTConfigurationAddsRootProviderWithoutChangingProfile() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-codex-config-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            let manager = CodexConfigurationManager(homeLocator: locator)
            let configURL = try locator.homeURL().appending(path: "config.toml")
            let profileConfiguration = """
            [profiles.work]
            model_provider = "Databricks"
            """
            try Data(profileConfiguration.utf8).write(to: configURL)

            #expect(try await manager.configureChatGPTSubscription())
            #expect(try String(contentsOf: configURL, encoding: .utf8) == """
            model_provider = "openai"

            \(profileConfiguration)
            """)
        }

        @Test
        func chatGPTConfigurationHandlesQuotedKeyAfterMultilineValue() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-codex-config-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            let manager = CodexConfigurationManager(homeLocator: locator)
            let configURL = try locator.homeURL().appending(path: "config.toml")
            let originalConfiguration = #"""
            developer_instructions = """
            [Review Guidelines]
            Preserve this text.
            """
            "model_provider" = "Databricks" # selected by Dahlia

            [profiles.work]
            model_provider = "Databricks"
            """#
            try Data(originalConfiguration.utf8).write(to: configURL)

            #expect(try await manager.configureChatGPTSubscription())
            let configuration = try String(contentsOf: configURL, encoding: .utf8)
            #expect(configuration.contains(#""model_provider" = "openai" # selected by Dahlia"#))
            #expect(!configuration.contains(#"model_provider = "openai""#))
            #expect(configuration.contains("""
            [profiles.work]
            model_provider = "Databricks"
            """))
            #expect(configuration.contains("""
            [Review Guidelines]
            Preserve this text.
            """))
        }

        @Test
        func databricksConfigurationRejectsProfileWithoutHTTPSWorkspace() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-codex-config-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let manager = CodexConfigurationManager(
                homeLocator: ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            )
            let profile = try await databricksProfile(name: "DEFAULT", host: "http://dbc.example.com")

            await #expect(throws: CodexConfigurationError.self) {
                try await manager.configureDatabricks(profile: profile)
            }
        }

        private func databricksProfile(name: String, host: String) async throws -> DatabricksCLIClient.Profile {
            let response = try JSONSerialization.data(withJSONObject: [
                "profiles": [
                    [
                        "name": name,
                        "host": host,
                        "auth_type": "databricks-cli",
                    ],
                ],
            ])
            let client = DatabricksCLIClient { _ in
                .init(standardOutput: response, standardError: Data(), terminationStatus: 0)
            }
            return try #require(await client.profiles().first)
        }
    }
#endif
