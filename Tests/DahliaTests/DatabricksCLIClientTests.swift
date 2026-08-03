import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct DatabricksCLIClientTests {
        @Test
        func profilesLoadsOAuthCLIProfilesWithoutValidation() async throws {
            let recorder = CommandRecorder()
            let response = Data(
                """
                {"profiles":[
                    {"name":"WORK","host":"https://work.example.com","auth_type":"pat","workspace_id":"111"},
                    {"name":"DEV","host":"https://dev.example.com/","auth_type":"databricks-cli","workspace_id":222}
                ]}
                """.utf8
            )
            let client = DatabricksCLIClient { arguments in
                await recorder.record(arguments)
                return .init(standardOutput: response, standardError: Data(), terminationStatus: 0)
            }

            let profiles = try await client.profiles()

            #expect(profiles.map(\.name) == ["DEV"])
            #expect(profiles.map(\.workspaceID) == ["222"])
            #expect(await recorder.commands == [
                [
                    "auth",
                    "profiles",
                    "--skip-validate",
                    "--output",
                    "json",
                ],
            ])
        }

        @Test
        func profilesReportsCLIErrorOutput() async {
            let client = DatabricksCLIClient { _ in
                .init(
                    standardOutput: Data(),
                    standardError: Data("profile file is invalid".utf8),
                    terminationStatus: 1
                )
            }

            do {
                _ = try await client.profiles()
                Issue.record("Expected profile loading to fail")
            } catch {
                #expect(error.localizedDescription.contains("profile file is invalid"))
            }
        }

        @Test
        func validCachedCredentialsDoNotStartBrowserLogin() async throws {
            let recorder = CommandRecorder()
            let client = DatabricksCLIClient { arguments in
                await recorder.record(arguments)
                return .init(standardOutput: Data(), standardError: Data(), terminationStatus: 0)
            }

            let result = try await client.ensureAuthenticated(profileName: "DEFAULT")

            #expect(result == .alreadyAuthenticated)
            #expect(await recorder.commands == [
                [
                    "auth",
                    "token",
                    "--profile",
                    "DEFAULT",
                    "--output",
                    "json",
                ],
            ])
        }

        @Test
        func missingCredentialsStartBrowserLoginAndRecheckToken() async throws {
            let responder = ScriptedCommandResponder(outputs: [
                .failure("cache: databricks OAuth is not configured for this host"),
                .success(),
                .success(),
            ])
            let client = DatabricksCLIClient { arguments in
                await responder.run(arguments)
            }

            let result = try await client.ensureAuthenticated(profileName: "Team Profile")

            #expect(result == .browserLoginCompleted)
            #expect(await responder.commands == [
                [
                    "auth",
                    "token",
                    "--profile",
                    "Team Profile",
                    "--output",
                    "json",
                ],
                [
                    "auth",
                    "login",
                    "--profile",
                    "Team Profile",
                ],
                [
                    "auth",
                    "token",
                    "--profile",
                    "Team Profile",
                    "--output",
                    "json",
                ],
            ])
        }

        @Test
        func unrelatedTokenFailureDoesNotStartBrowserLogin() async {
            let responder = ScriptedCommandResponder(outputs: [
                .failure("TLS handshake failed"),
            ])
            let client = DatabricksCLIClient { arguments in
                await responder.run(arguments)
            }

            await #expect(throws: DatabricksCLIError.self) {
                _ = try await client.ensureAuthenticated(profileName: "DEFAULT")
            }
            #expect(await responder.commands.count == 1)
        }

        @Test
        func browserLoginFailureIsReportedWithoutRecheckingToken() async {
            let responder = ScriptedCommandResponder(outputs: [
                .failure("A new access token could not be retrieved because the refresh token is invalid."),
                .failure("browser login timed out"),
            ])
            let client = DatabricksCLIClient { arguments in
                await responder.run(arguments)
            }

            do {
                _ = try await client.ensureAuthenticated(profileName: "DEFAULT")
                Issue.record("Expected browser login to fail")
            } catch {
                #expect(error.localizedDescription.contains("browser login timed out"))
            }
            #expect(await responder.commands.count == 2)
        }

        @Test
        func tokenFailureAfterBrowserLoginIsReported() async {
            let responder = ScriptedCommandResponder(outputs: [
                .failure("A new access token could not be retrieved because the refresh token is invalid."),
                .success(),
                .failure("token still unavailable"),
            ])
            let client = DatabricksCLIClient { arguments in
                await responder.run(arguments)
            }

            do {
                _ = try await client.ensureAuthenticated(profileName: "DEFAULT")
                Issue.record("Expected token recheck to fail")
            } catch {
                #expect(error.localizedDescription.contains("token still unavailable"))
            }
            #expect(await responder.commands.count == 3)
        }

        @Test
        func cancellingBrowserLoginDoesNotRecheckToken() async {
            let loginStarted = AsyncStream.makeStream(of: Void.self)
            let releaseLogin = AsyncStream.makeStream(of: Void.self)
            let recorder = CommandRecorder()
            let client = DatabricksCLIClient { arguments in
                await recorder.record(arguments)
                if arguments.prefix(2) == ["auth", "token"] {
                    return .failure("A new access token could not be retrieved because the refresh token is invalid.")
                }
                loginStarted.continuation.yield()
                for await _ in releaseLogin.stream {
                    break
                }
                return .success()
            }

            let authentication = Task {
                try await client.ensureAuthenticated(profileName: "DEFAULT")
            }
            for await _ in loginStarted.stream {
                break
            }
            authentication.cancel()
            releaseLogin.continuation.yield()

            await #expect(throws: CancellationError.self) {
                try await authentication.value
            }
            #expect(await recorder.commands.count == 2)
        }

        @Test
        func commandLineToolSearchPathIncludesHomebrewLocationsOnce() {
            let searchPath = CommandLineToolLocator.searchPath(environment: [
                "PATH": "/usr/bin:/opt/homebrew/bin",
            ])

            #expect(searchPath == "/usr/bin:/opt/homebrew/bin:/usr/local/bin")
        }

        @Test
        func executableRunnerReadsProfileJSONWithoutBlockingTasks() async throws {
            let executableURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-databricks-cli-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: executableURL) }
            let script = """
            #!/bin/sh
            printf '%s' '{"profiles":[{"name":"DEFAULT","host":"https://dbc.example.com","auth_type":"databricks-cli"}]}'
            """
            try Data(script.utf8).write(to: executableURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
            let client = DatabricksCLIClient(executableURL: executableURL)

            let profiles = try await client.profiles()

            #expect(profiles.map(\.name) == ["DEFAULT"])
        }

        private actor CommandRecorder {
            private(set) var commands: [[String]] = []

            func record(_ arguments: [String]) {
                commands.append(arguments)
            }
        }

        private actor ScriptedCommandResponder {
            private(set) var commands: [[String]] = []
            private var outputs: [DatabricksCLIClient.CommandOutput]

            init(outputs: [DatabricksCLIClient.CommandOutput]) {
                self.outputs = outputs
            }

            func run(_ arguments: [String]) -> DatabricksCLIClient.CommandOutput {
                commands.append(arguments)
                return outputs.removeFirst()
            }
        }
    }

    private extension DatabricksCLIClient.CommandOutput {
        static func success() -> Self {
            .init(standardOutput: Data(), standardError: Data(), terminationStatus: 0)
        }

        static func failure(_ message: String) -> Self {
            .init(standardOutput: Data(), standardError: Data(message.utf8), terminationStatus: 1)
        }
    }
#endif
