import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct DatabricksAccountControllerTests {
        @Test
        func validProfileIsDiscoveredWithoutChangingCodexConfiguration() async {
            let response = Data(
                #"{"profiles":[{"name":"DEFAULT","host":"https://dbc.example.com","auth_type":"databricks-cli"}]}"#.utf8
            )
            let commands = CommandRecorder(response: response)
            let controller = DatabricksAccountController(
                client: DatabricksCLIClient { await commands.run($0) }
            )

            let resolvedProfile = await controller.prepare(profileName: "DEFAULT")

            #expect(resolvedProfile == nil)
            #expect(controller.isConfigured)
            #expect(controller.configuredProfileName == "DEFAULT")
            #expect(await commands.values == [
                ["auth", "profiles", "--skip-validate", "--output", "json"],
            ])
        }

        @Test
        func cancelledProfileLoadDoesNotSelectProfile() async {
            let started = AsyncStream.makeStream(of: Void.self)
            let release = AsyncStream.makeStream(of: Void.self)
            let response = Data(
                #"{"profiles":[{"name":"OLD","host":"https://old.example.com","auth_type":"databricks-cli"}]}"#.utf8
            )
            let controller = DatabricksAccountController(client: DatabricksCLIClient { _ in
                started.continuation.yield()
                for await _ in release.stream { break }
                return .init(standardOutput: response, standardError: Data(), terminationStatus: 0)
            })

            let preparation = Task { await controller.prepare(profileName: "OLD") }
            for await _ in started.stream { break }
            preparation.cancel()
            release.continuation.yield()

            #expect(await preparation.value == nil)
            #expect(!controller.isConfigured)
            #expect(controller.configuredProfileName == nil)
        }

        @Test
        func missingCLIIsReportedWithoutTreatingEmptyProfilesAsAnError() async {
            let controller = DatabricksAccountController(
                client: DatabricksCLIClient(executableLocator: { nil })
            )

            _ = await controller.prepare(profileName: "")

            #expect(controller.isCLIAvailable == false)
            #expect(controller.profiles.isEmpty)
            #expect(controller.errorMessage == nil)
        }

        @Test
        func missingSelectedProfileIsCleared() async {
            let response = Data(
                #"{"profiles":[{"name":"DEFAULT","host":"https://dbc.example.com","auth_type":"databricks-cli"}]}"#.utf8
            )
            let commands = CommandRecorder(response: response)
            let controller = DatabricksAccountController(
                client: DatabricksCLIClient { await commands.run($0) }
            )

            let resolvedProfile = await controller.prepare(profileName: "MISSING")

            #expect(resolvedProfile?.isEmpty == true)
            #expect(!controller.isConfigured)
            #expect(await commands.values.count == 1)
        }

        @Test
        func workspaceSignInCreatesRequestedProfileWithoutApplyingCodexConfiguration() async {
            let responder = WorkspaceSignInResponder(
                initialProfiles: #"{"profiles":[]}"#,
                signedInProfiles: #"{"profiles":[{"name":"DEFAULT","host":"https://dbc.example.com","auth_type":"databricks-cli"}]}"#
            )
            let controller = DatabricksAccountController(
                client: DatabricksCLIClient { await responder.run($0) }
            )

            let profileName = await controller.signIn(
                workspaceURL: "https://dbc.example.com/",
                profileName: "DEFAULT"
            )

            #expect(profileName == "DEFAULT")
            #expect(controller.isConfigured)
            #expect(await responder.commands == [
                ["auth", "profiles", "--skip-validate", "--output", "json"],
                ["auth", "login", "--host", "https://dbc.example.com", "--profile", "DEFAULT"],
                ["auth", "profiles", "--skip-validate", "--output", "json"],
            ])
        }

        @Test
        func workspaceSignInDoesNotOverwriteProfileForAnotherHost() async {
            let profiles = #"{"profiles":[{"name":"DEFAULT","host":"https://other.example.com","auth_type":"databricks-cli"}]}"#
            let responder = WorkspaceSignInResponder(initialProfiles: profiles, signedInProfiles: profiles)
            let controller = DatabricksAccountController(
                client: DatabricksCLIClient { await responder.run($0) }
            )

            let profileName = await controller.signIn(
                workspaceURL: "https://dbc.example.com",
                profileName: "DEFAULT"
            )

            #expect(profileName == nil)
            #expect(controller.errorMessage == L10n.databricksProfileAlreadyExists("DEFAULT"))
            #expect(await responder.commands.count == 1)
        }

        @Test
        func terminalInstallResultIsForwardedWithoutLaunchingTerminalInTests() {
            let controller = DatabricksAccountController(
                cliInstaller: StubCLIInstaller(result: .commandCopied)
            )

            #expect(controller.installCLIInTerminal() == .commandCopied)
        }

        private actor CommandRecorder {
            private(set) var values: [[String]] = []
            let response: Data

            init(response: Data) {
                self.response = response
            }

            func run(_ arguments: [String]) -> DatabricksCLIClient.CommandOutput {
                values.append(arguments)
                return .init(standardOutput: response, standardError: Data(), terminationStatus: 0)
            }
        }

        private actor WorkspaceSignInResponder {
            private(set) var commands: [[String]] = []
            private let initialProfiles: Data
            private let signedInProfiles: Data
            private var profileRequestCount = 0

            init(initialProfiles: String, signedInProfiles: String) {
                self.initialProfiles = Data(initialProfiles.utf8)
                self.signedInProfiles = Data(signedInProfiles.utf8)
            }

            func run(_ arguments: [String]) -> DatabricksCLIClient.CommandOutput {
                commands.append(arguments)
                if arguments.prefix(2) == ["auth", "profiles"] {
                    profileRequestCount += 1
                    return .init(
                        standardOutput: profileRequestCount == 1 ? initialProfiles : signedInProfiles,
                        standardError: Data(),
                        terminationStatus: 0
                    )
                }
                return .init(standardOutput: Data(), standardError: Data(), terminationStatus: 0)
            }
        }

        private struct StubCLIInstaller: DatabricksCLIInstalling {
            let result: DatabricksCLIInstallationResult

            func installInTerminal() -> DatabricksCLIInstallationResult {
                result
            }
        }
    }
#endif
