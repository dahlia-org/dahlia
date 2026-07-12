import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct DatabricksCLIClientTests {
        @Test
        func profilesDecodesAndSortsCLIProfilesWithoutValidation() async throws {
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

            #expect(profiles.map(\.name) == ["DEV", "WORK"])
            #expect(await recorder.arguments == [
                "auth",
                "profiles",
                "--skip-validate",
                "--output",
                "json",
            ])
        }

        @Test
        func signInUsesNamedProfileAndBoundedTimeout() async throws {
            let recorder = CommandRecorder()
            let client = DatabricksCLIClient { arguments in
                await recorder.record(arguments)
                return .init(standardOutput: Data(), standardError: Data(), terminationStatus: 0)
            }

            try await client.signIn(profile: " DAHLIA ")

            #expect(await recorder.arguments == [
                "auth",
                "login",
                "--profile",
                "DAHLIA",
                "--timeout",
                "5m",
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
            #expect(await recorder.arguments == [
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
            let client = DatabricksCLIClient { _ in
                .init(standardOutput: Data("{}".utf8), standardError: Data(), terminationStatus: 0)
            }

            await #expect(throws: DatabricksCLIError.self) {
                _ = try await client.accessToken(profile: "DAHLIA")
            }
        }

        @Test
        func commandFailureIncludesCLIErrorDetail() async {
            let client = DatabricksCLIClient { _ in
                .init(
                    standardOutput: Data(),
                    standardError: Data("OAuth session expired".utf8),
                    terminationStatus: 1
                )
            }

            do {
                _ = try await client.accessToken(profile: "DAHLIA")
                Issue.record("Expected the CLI command to fail")
            } catch {
                #expect(error.localizedDescription.contains("OAuth session expired"))
            }
        }

        @Test
        func credentialResolverUsesCLIOnlyForDatabricks() async throws {
            let recorder = CommandRecorder()
            let response = Data(#"{"access_token":"short-lived-token"}"#.utf8)
            let client = DatabricksCLIClient { arguments in
                await recorder.record(arguments)
                return .init(standardOutput: response, standardError: Data(), terminationStatus: 0)
            }
            let resolver = LLMCredentialResolver(databricksClient: client)

            let openAIToken = try await resolver.accessToken(
                provider: .openAI,
                openAIAPIToken: "openai-token",
                databricksProfile: "DAHLIA"
            )
            #expect(openAIToken == "openai-token")
            #expect(await recorder.arguments == nil)

            let databricksToken = try await resolver.accessToken(
                provider: .databricks,
                openAIAPIToken: "legacy-token",
                databricksProfile: "DAHLIA"
            )
            #expect(databricksToken == "short-lived-token")
            #expect(await recorder.arguments?.prefix(2) == ["auth", "token"])
        }
    }

    private actor CommandRecorder {
        private(set) var arguments: [String]?

        func record(_ arguments: [String]) {
            self.arguments = arguments
        }
    }
#endif
