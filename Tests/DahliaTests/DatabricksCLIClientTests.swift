import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct DatabricksCLIClientTests {
        @Test
        func profilesReturnsOnlyOAuthU2MProfilesWithoutValidation() async throws {
            let recorder = CommandRecorder()
            let response = Data(
                #"{"profiles":[{"name":"WORK","host":"https://work.example.com","auth_type":"pat"},{"name":"DEV","host":"https://dev.example.com","auth_type":"databricks-cli"}]}"#
                    .utf8
            )
            let client = DatabricksCLIClient { arguments in
                await recorder.record(arguments)
                return .init(standardOutput: response, standardError: Data(), terminationStatus: 0)
            }

            let profiles = try await client.profiles()

            #expect(profiles.map(\.name) == ["DEV"])
            #expect(await recorder.commands.last == [
                "auth",
                "profiles",
                "--skip-validate",
                "--output",
                "json",
            ])
        }

        @Test
        func accessTokenDecodesOAuthTokenWithoutPersistingIt() async throws {
            let recorder = CommandRecorder()
            let response = Data(#"{"access_token":"oauth-token","token_type":"Bearer","expiry":"2026-07-13T01:00:00Z"}"#.utf8)
            let client = DatabricksCLIClient { arguments in
                await recorder.record(arguments)
                return .init(standardOutput: response, standardError: Data(), terminationStatus: 0)
            }

            let token = try await client.accessToken(profile: "Dahlia Dev")

            #expect(token == "oauth-token")
            #expect(await recorder.commands.last == [
                "auth",
                "token",
                "--profile",
                "Dahlia Dev",
                "--output",
                "json",
                "--timeout",
                "30s",
            ])
        }

        @Test
        func accessTokenRejectsInvalidCLIResponse() async {
            let recorder = CommandRecorder()
            let client = DatabricksCLIClient { arguments in
                await recorder.record(arguments)
                return .init(standardOutput: Data("{}".utf8), standardError: Data(), terminationStatus: 0)
            }

            await #expect(throws: DatabricksCLIError.self) {
                _ = try await client.accessToken(profile: "WORK")
            }
            #expect(await recorder.commands.count == 1)
        }

        @Test
        func accessTokenReauthenticatesExpiredOAuthSessionAndRetries() async throws {
            let recorder = CommandRecorder()
            let response = Data(#"{"access_token":"renewed-token"}"#.utf8)
            let client = DatabricksCLIClient { arguments in
                let commandCount = await recorder.record(arguments)
                switch commandCount {
                case 1:
                    return .init(
                        standardOutput: Data(),
                        standardError: Data("OAuth session expired. Run databricks auth login.".utf8),
                        terminationStatus: 1
                    )
                case 2:
                    return .init(standardOutput: Data(), standardError: Data(), terminationStatus: 0)
                default:
                    return .init(standardOutput: response, standardError: Data(), terminationStatus: 0)
                }
            }

            let token = try await client.accessToken(profile: "WORK")

            #expect(token == "renewed-token")
            #expect(await recorder.commands == [
                ["auth", "token", "--profile", "WORK", "--output", "json", "--timeout", "30s"],
                ["auth", "login", "--profile", "WORK", "--timeout", "5m"],
                ["auth", "token", "--profile", "WORK", "--output", "json", "--timeout", "30s"],
            ])
        }

        @Test
        func accessTokenDoesNotOpenLoginForNetworkFailureWithLoginSuggestion() async {
            let recorder = CommandRecorder()
            let client = DatabricksCLIClient { arguments in
                await recorder.record(arguments)
                return .init(
                    standardOutput: Data(),
                    standardError: Data(
                        "dial tcp: network is unreachable\nTry logging in again with: databricks auth login --profile WORK".utf8
                    ),
                    terminationStatus: 1
                )
            }

            do {
                _ = try await client.accessToken(profile: "WORK")
                Issue.record("Expected the CLI command to fail")
            } catch {
                #expect(error.localizedDescription.contains("network is unreachable"))
            }
            #expect(await recorder.commands.count == 1)
            #expect(await recorder.commands.first?.prefix(2) == ["auth", "token"])
        }

        @Test
        func accessTokenReturnsLoginFailureWithoutRetryingToken() async {
            let recorder = CommandRecorder()
            let client = DatabricksCLIClient { arguments in
                let commandCount = await recorder.record(arguments)
                if commandCount == 1 {
                    return .init(
                        standardOutput: Data(),
                        standardError: Data("invalid_grant: refresh token has expired".utf8),
                        terminationStatus: 1
                    )
                }
                return .init(
                    standardOutput: Data(),
                    standardError: Data("browser sign-in was cancelled".utf8),
                    terminationStatus: 1
                )
            }

            do {
                _ = try await client.accessToken(profile: "WORK")
                Issue.record("Expected browser login to fail")
            } catch {
                #expect(error.localizedDescription.contains("browser sign-in was cancelled"))
            }
            #expect(await recorder.commands.count == 2)
            #expect(await recorder.commands.last?.prefix(2) == ["auth", "login"])
        }

        @Test
        func credentialResolverUsesCLIOnlyForDatabricksOAuth() async throws {
            let recorder = CommandRecorder()
            let response = Data(#"{"access_token":"short-lived-token"}"#.utf8)
            let client = DatabricksCLIClient { arguments in
                await recorder.record(arguments)
                return .init(standardOutput: response, standardError: Data(), terminationStatus: 0)
            }
            let resolver = LLMCredentialResolver(databricksClient: client)

            let openAIToken = try await resolver.accessToken(
                provider: .openAI,
                apiToken: "openai-token",
                databricksAuthenticationType: .personalAccessToken,
                databricksProfile: ""
            )
            #expect(openAIToken == "openai-token")
            #expect(await recorder.commands.isEmpty)

            let personalAccessToken = try await resolver.accessToken(
                provider: .databricks,
                apiToken: "databricks-pat",
                databricksAuthenticationType: .personalAccessToken,
                databricksProfile: ""
            )
            #expect(personalAccessToken == "databricks-pat")
            #expect(await recorder.commands.isEmpty)

            let oauthToken = try await resolver.accessToken(
                provider: .databricks,
                apiToken: "unused-token",
                databricksAuthenticationType: .oauthCLI,
                databricksProfile: "WORK"
            )
            #expect(oauthToken == "short-lived-token")
            #expect(await recorder.commands.last?.prefix(2) == ["auth", "token"])
        }

        @Test
        func credentialResolverRequiresDatabricksPersonalAccessToken() async {
            let recorder = CommandRecorder()
            let client = DatabricksCLIClient { arguments in
                await recorder.record(arguments)
                return .init(standardOutput: Data(), standardError: Data(), terminationStatus: 0)
            }
            let resolver = LLMCredentialResolver(databricksClient: client)

            await #expect(throws: LLMCredentialError.self) {
                _ = try await resolver.accessToken(
                    provider: .databricks,
                    apiToken: "  ",
                    databricksAuthenticationType: .personalAccessToken,
                    databricksProfile: "WORK"
                )
            }
            #expect(await recorder.commands.isEmpty)
        }
    }

    private actor CommandRecorder {
        private(set) var commands: [[String]] = []

        @discardableResult
        func record(_ arguments: [String]) -> Int {
            commands.append(arguments)
            return commands.count
        }
    }
#endif
