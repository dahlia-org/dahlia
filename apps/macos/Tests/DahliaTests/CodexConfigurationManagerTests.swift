import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct CodexConfigurationManagerTests {
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

            #expect(try manager.configureDatabricks(profile: profile))
            #expect(try !manager.configureDatabricks(profile: profile))

            let configURL = try ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
                .homeURL()
                .appending(path: "config.toml")
            let configuration = try String(contentsOf: configURL, encoding: .utf8)
            #expect(configuration.contains(#"model_provider = "Databricks""#))
            #expect(!configuration.contains("[profiles."))
            #expect(configuration.contains(#"base_url = "https://dbc.example.com/ai-gateway/codex/v1""#))
            #expect(configuration.contains(#"wire_api = "responses""#))
            #expect(configuration.contains(#"--profile 'Team'\"'\"'s Profile'"#))
            #expect(configuration.contains("/usr/bin/plutil -extract access_token raw -o - -"))
            #expect(!configuration.contains("jq"))
            #expect(configuration.contains("refresh_interval_ms = 1800000"))
            let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }

        @Test
        func chatGPTConfigurationRemovesDatabricksConfiguration() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-codex-config-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            let manager = CodexConfigurationManager(homeLocator: locator)
            let profile = try await databricksProfile(name: "DEFAULT", host: "https://dbc.example.com")
            _ = try manager.configureDatabricks(profile: profile)

            #expect(try manager.configureChatGPTSubscription())
            #expect(try !manager.configureChatGPTSubscription())
            #expect(try !FileManager.default.fileExists(atPath: locator.homeURL().appending(path: "config.toml").path))
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

            #expect(throws: CodexConfigurationError.self) {
                try manager.configureDatabricks(profile: profile)
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
