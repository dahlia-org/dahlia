import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    // swiftlint:disable:next type_body_length
    struct DatabricksAccountControllerTests {
        @Test
        func invalidSelectedProviderIsNotTreatedAsConfiguredChatGPT() {
            let provider = AppSettings.configuredCodexAccountProvider(
                selectedProviderRawValue: "future-provider",
                selectedDatabricksProfile: "",
                configuredProviderRawValue: AIAccountProvider.chatGPTSubscription.rawValue,
                configuredDatabricksProfile: ""
            )

            #expect(provider == nil)
        }

        @Test
        func validProfileConfiguresCodexAndLoadsModels() async {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-databricks-account-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let response = Data(
                #"{"profiles":[{"name":"DEFAULT","host":"https://dbc.example.com","auth_type":"databricks-cli"}]}"#.utf8
            )
            let client = DatabricksCLIClient { _ in
                .init(standardOutput: response, standardError: Data(), terminationStatus: 0)
            }
            let service = CodexAppServerService {
                TestCodexAppServerTransport(mode: .models)
            }
            let configurationStore = TestCodexAccountConfigurationStore()
            let controller = DatabricksAccountController(
                client: client,
                configurationManager: CodexConfigurationManager(
                    homeLocator: ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
                ),
                service: service,
                configurationStore: configurationStore
            )

            let resolvedProfile = await controller.prepare(profileName: "DEFAULT")

            #expect(resolvedProfile == nil)
            #expect(controller.isConfigured)
            #expect(controller.errorMessage == nil)
            #expect(configurationStore.configuredProviderRawValue == AIAccountProvider.databricks.rawValue)
            #expect(configurationStore.configuredDatabricksProfile == "DEFAULT")
            #expect(AppSettings.configuredCodexAccountProvider(
                selectedProviderRawValue: AIAccountProvider.databricks.rawValue,
                selectedDatabricksProfile: "DEFAULT",
                configuredProviderRawValue: configurationStore.configuredProviderRawValue,
                configuredDatabricksProfile: configurationStore.configuredDatabricksProfile
            ) == .databricks)
            #expect(AppSettings.configuredCodexAccountProvider(
                selectedProviderRawValue: AIAccountProvider.databricks.rawValue,
                selectedDatabricksProfile: "OTHER",
                configuredProviderRawValue: configurationStore.configuredProviderRawValue,
                configuredDatabricksProfile: configurationStore.configuredDatabricksProfile
            ) == nil)
            await service.shutdown()
        }

        @Test
        func cancelledProfileLoadDoesNotApplyConfiguration() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-databricks-cancellation-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            let configURL = try locator.homeURL().appending(path: "config.toml")
            let started = AsyncStream.makeStream(of: Void.self)
            let release = AsyncStream.makeStream(of: Void.self)
            let response = Data(
                #"{"profiles":[{"name":"OLD","host":"https://old.example.com","auth_type":"databricks-cli"}]}"#.utf8
            )
            let client = DatabricksCLIClient { _ in
                started.continuation.yield()
                for await _ in release.stream {
                    break
                }
                return .init(standardOutput: response, standardError: Data(), terminationStatus: 0)
            }
            let service = CodexAppServerService {
                TestCodexAppServerTransport(mode: .models)
            }
            let configurationStore = TestCodexAccountConfigurationStore(configuredProvider: .databricks)
            let controller = DatabricksAccountController(
                client: client,
                configurationManager: CodexConfigurationManager(homeLocator: locator),
                service: service,
                configurationStore: configurationStore
            )

            let preparation = Task { await controller.prepare(profileName: "OLD") }
            for await _ in started.stream {
                break
            }
            preparation.cancel()
            release.continuation.yield()
            _ = await preparation.value

            #expect(!FileManager.default.fileExists(atPath: configURL.path))
            #expect(configurationStore.configuredProviderRawValue == AIAccountProvider.databricks.rawValue)
            await service.shutdown()
        }

        @Test
        func failedBrowserLoginPreservesExistingConfiguration() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-databricks-login-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            let configURL = try locator.homeURL().appending(path: "config.toml")
            let originalConfiguration = Data("existing configuration".utf8)
            try originalConfiguration.write(to: configURL)
            let profileResponse = Data(
                #"{"profiles":[{"name":"DEFAULT","host":"https://dbc.example.com","auth_type":"databricks-cli"}]}"#.utf8
            )
            let responder = ControllerAuthenticationResponder(profileResponse: profileResponse)
            let client = DatabricksCLIClient { arguments in
                await responder.run(arguments)
            }
            let service = CodexAppServerService {
                TestCodexAppServerTransport(mode: .models)
            }
            let configurationStore = TestCodexAccountConfigurationStore(
                configuredProvider: .databricks,
                configuredDatabricksProfile: "DEFAULT"
            )
            let controller = DatabricksAccountController(
                client: client,
                configurationManager: CodexConfigurationManager(homeLocator: locator),
                service: service,
                configurationStore: configurationStore
            )

            _ = await controller.prepare(profileName: "DEFAULT")

            #expect(FileManager.default.contents(atPath: configURL.path) == originalConfiguration)
            #expect(configurationStore.configuredProviderRawValue == AIAccountProvider.databricks.rawValue)
            #expect(configurationStore.configuredDatabricksProfile == "DEFAULT")
            #expect(!controller.isConfigured)
            #expect(controller.errorMessage?.contains("browser login timed out") == true)
            #expect(await responder.commands.count == 3)
            await service.shutdown()
        }

        @Test
        func invalidWorkspaceDoesNotStartBrowserLogin() async {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-databricks-invalid-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let profileResponse = Data(
                #"{"profiles":[{"name":"DEFAULT","auth_type":"databricks-cli"}]}"#.utf8
            )
            let responder = ControllerAuthenticationResponder(profileResponse: profileResponse)
            let client = DatabricksCLIClient { arguments in
                await responder.run(arguments)
            }
            let service = CodexAppServerService {
                TestCodexAppServerTransport(mode: .models)
            }
            let controller = DatabricksAccountController(
                client: client,
                configurationManager: CodexConfigurationManager(
                    homeLocator: ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
                ),
                service: service,
                configurationStore: TestCodexAccountConfigurationStore()
            )

            _ = await controller.prepare(profileName: "DEFAULT")

            #expect(!controller.isConfigured)
            #expect(controller.errorMessage == L10n.databricksWorkspaceURLInvalid)
            #expect(await responder.commands.count == 1)
            await service.shutdown()
        }

        @Test
        func missingCLIIsReportedWithoutTreatingEmptyProfilesAsAnError() async {
            let controller = DatabricksAccountController(
                client: DatabricksCLIClient(executableLocator: { nil }),
                configurationStore: TestCodexAccountConfigurationStore()
            )

            _ = await controller.prepare(profileName: "")

            #expect(controller.isCLIAvailable == false)
            #expect(controller.profiles.isEmpty)
            #expect(controller.errorMessage == nil)

            _ = await controller.signIn(workspaceURL: "https://dbc.example.com", profileName: "DEFAULT")
            #expect(controller.isCLIAvailable == false)
            #expect(controller.errorMessage == nil)
        }

        @Test
        func CLIAvailabilityCanBeCheckedAgainAfterInstallation() async {
            let responder = RecoveringCLIResponder()
            let controller = DatabricksAccountController(
                client: DatabricksCLIClient { try await responder.run($0) },
                configurationStore: TestCodexAccountConfigurationStore()
            )

            _ = await controller.prepare(profileName: "")
            #expect(controller.isCLIAvailable == false)

            await responder.install()
            let resolvedProfile = await controller.prepare(profileName: "")

            #expect(controller.isCLIAvailable == true)
            #expect(controller.profiles.map(\.name) == ["DEFAULT"])
            #expect(resolvedProfile == "DEFAULT")
        }

        @Test
        func workspaceSignInUsesTheRequestedProfileNameAndConfiguresCodex() async {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-databricks-new-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let responder = WorkspaceSignInResponder(
                initialProfiles: """
                {"profiles":[
                    {"name":"Dahlia","host":"https://pat.example.com","auth_type":"pat"},
                    {"name":"Dahlia 2","host":"https://other.example.com","auth_type":"databricks-cli"}
                ]}
                """,
                signedInProfiles: """
                {"profiles":[
                    {"name":"Dahlia","host":"https://pat.example.com","auth_type":"pat"},
                    {"name":"Dahlia 2","host":"https://other.example.com","auth_type":"databricks-cli"},
                    {"name":"DEFAULT","host":"https://dbc.example.com","auth_type":"databricks-cli"}
                ]}
                """
            )
            let service = CodexAppServerService { TestCodexAppServerTransport(mode: .models) }
            let configurationStore = TestCodexAccountConfigurationStore()
            let controller = DatabricksAccountController(
                client: DatabricksCLIClient { await responder.run($0) },
                configurationManager: CodexConfigurationManager(
                    homeLocator: ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
                ),
                service: service,
                configurationStore: configurationStore
            )

            let profileName = await controller.signIn(
                workspaceURL: "https://dbc.example.com/",
                profileName: "DEFAULT"
            )

            #expect(profileName == "DEFAULT")
            #expect(controller.isConfigured)
            #expect(configurationStore.configuredDatabricksProfile == "DEFAULT")
            #expect(await responder.commands == [
                ["auth", "profiles", "--skip-validate", "--output", "json"],
                ["auth", "login", "--host", "https://dbc.example.com", "--profile", "DEFAULT"],
                ["auth", "profiles", "--skip-validate", "--output", "json"],
                ["auth", "token", "--profile", "DEFAULT", "--output", "json"],
            ])
            await service.shutdown()
        }

        @Test
        func workspaceSignInReusesOAuthProfileForTheSameHost() async {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-databricks-reused-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let profiles = """
            {"profiles":[
                {"name":"WORK","host":"https://DBC.EXAMPLE.COM:443/","auth_type":"databricks-cli"}
            ]}
            """
            let responder = WorkspaceSignInResponder(initialProfiles: profiles, signedInProfiles: profiles)
            let service = CodexAppServerService { TestCodexAppServerTransport(mode: .models) }
            let controller = DatabricksAccountController(
                client: DatabricksCLIClient { await responder.run($0) },
                configurationManager: CodexConfigurationManager(
                    homeLocator: ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
                ),
                service: service,
                configurationStore: TestCodexAccountConfigurationStore()
            )

            let profileName = await controller.signIn(
                workspaceURL: "https://dbc.example.com",
                profileName: "WORK"
            )

            #expect(profileName == "WORK")
            #expect(await responder.commands.contains(
                ["auth", "login", "--host", "https://dbc.example.com", "--profile", "WORK"]
            ))
            await service.shutdown()
        }

        @Test
        func workspaceSignInDoesNotOverwriteAnExistingProfileForAnotherHost() async {
            let profiles = """
            {"profiles":[
                {"name":"DEFAULT","host":"https://other.example.com","auth_type":"databricks-cli"}
            ]}
            """
            let responder = WorkspaceSignInResponder(initialProfiles: profiles, signedInProfiles: profiles)
            let service = CodexAppServerService { TestCodexAppServerTransport(mode: .models) }
            let controller = DatabricksAccountController(
                client: DatabricksCLIClient { await responder.run($0) },
                service: service,
                configurationStore: TestCodexAccountConfigurationStore()
            )

            let profileName = await controller.signIn(
                workspaceURL: "https://dbc.example.com",
                profileName: "DEFAULT"
            )

            #expect(profileName == nil)
            #expect(controller.errorMessage == L10n.databricksProfileAlreadyExists("DEFAULT"))
            #expect(await responder.commands == [
                ["auth", "profiles", "--skip-validate", "--output", "json"],
            ])
            await service.shutdown()
        }

        @Test
        func failedModelValidationRestoresPreviousConfiguration() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-databricks-model-failure-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            let configURL = try locator.homeURL().appending(path: "config.toml")
            let originalConfiguration = Data("existing configuration".utf8)
            try originalConfiguration.write(to: configURL)
            let signedInProfiles = """
            {"profiles":[
                {"name":"OLD","host":"https://old.example.com","auth_type":"databricks-cli"},
                {"name":"Dahlia","host":"https://dbc.example.com","auth_type":"databricks-cli"}
            ]}
            """
            let responder = WorkspaceSignInResponder(
                initialProfiles: #"{"profiles":[]}"#,
                signedInProfiles: signedInProfiles
            )
            let service = CodexAppServerService {
                TestCodexAppServerTransport(mode: .invalidInitializeResponse)
            }
            let configurationStore = TestCodexAccountConfigurationStore(
                configuredProvider: .databricks,
                configuredDatabricksProfile: "OLD"
            )
            let controller = DatabricksAccountController(
                client: DatabricksCLIClient { await responder.run($0) },
                configurationManager: CodexConfigurationManager(homeLocator: locator),
                service: service,
                configurationStore: configurationStore
            )

            _ = await controller.signIn(workspaceURL: "https://dbc.example.com", profileName: "Dahlia")

            #expect(FileManager.default.contents(atPath: configURL.path) == originalConfiguration)
            #expect(configurationStore.configuredDatabricksProfile == "OLD")
            #expect(controller.isConfigured)
            #expect(controller.configuredProfileName == "OLD")
            #expect(controller.errorMessage != nil)
            await service.shutdown()
        }

        @Test
        func failedProfileChangeReturnsPreviouslyConfiguredProfile() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-databricks-profile-rollback-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            let configURL = try locator.homeURL().appending(path: "config.toml")
            let originalConfiguration = Data("existing configuration".utf8)
            try originalConfiguration.write(to: configURL)
            let response = Data(
                """
                {"profiles":[
                    {"name":"OLD","host":"https://old.example.com","auth_type":"databricks-cli"},
                    {"name":"NEW","host":"https://new.example.com","auth_type":"databricks-cli"}
                ]}
                """.utf8
            )
            let service = CodexAppServerService {
                TestCodexAppServerTransport(mode: .invalidInitializeResponse)
            }
            let configurationStore = TestCodexAccountConfigurationStore(
                configuredProvider: .databricks,
                configuredDatabricksProfile: "OLD"
            )
            let controller = DatabricksAccountController(
                client: DatabricksCLIClient { _ in
                    .init(standardOutput: response, standardError: Data(), terminationStatus: 0)
                },
                configurationManager: CodexConfigurationManager(homeLocator: locator),
                service: service,
                configurationStore: configurationStore
            )

            let restoredProfile = await controller.prepare(profileName: "NEW")

            #expect(restoredProfile == "OLD")
            #expect(FileManager.default.contents(atPath: configURL.path) == originalConfiguration)
            #expect(configurationStore.configuredDatabricksProfile == "OLD")
            await service.shutdown()
        }

        @Test
        func failedDatabricksActivationKeepsSetupVisibleUntilDismissed() async {
            let configurationStore = TestCodexAccountConfigurationStore(
                selectedProvider: .databricks,
                configuredProvider: .chatGPTSubscription
            )
            let controller = DatabricksAccountController(
                client: DatabricksCLIClient { _ in
                    throw DatabricksCLIError.commandFailed(detail: "browser login failed")
                },
                configurationStore: configurationStore
            )

            _ = await controller.signIn(workspaceURL: "https://dbc.example.com", profileName: "DEFAULT")

            #expect(configurationStore.selectedProviderRawValue == AIAccountProvider.databricks.rawValue)
            #expect(configurationStore.configuredProviderRawValue == AIAccountProvider.chatGPTSubscription.rawValue)

            controller.restoreSelectedProvider()

            #expect(configurationStore.selectedProviderRawValue == AIAccountProvider.chatGPTSubscription.rawValue)
            #expect(configurationStore.configuredProviderRawValue == AIAccountProvider.chatGPTSubscription.rawValue)
        }

        @Test
        func failedProfileChangeDoesNotRestoreAnUnavailableProfile() async {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-databricks-missing-profile-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let response = Data(
                #"{"profiles":[{"name":"NEW","host":"https://new.example.com","auth_type":"databricks-cli"}]}"#.utf8
            )
            let service = CodexAppServerService {
                TestCodexAppServerTransport(mode: .invalidInitializeResponse)
            }
            let configurationStore = TestCodexAccountConfigurationStore(
                configuredProvider: .databricks,
                configuredDatabricksProfile: "OLD"
            )
            let controller = DatabricksAccountController(
                client: DatabricksCLIClient { _ in
                    .init(standardOutput: response, standardError: Data(), terminationStatus: 0)
                },
                configurationManager: CodexConfigurationManager(
                    homeLocator: ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
                ),
                service: service,
                configurationStore: configurationStore
            )

            let restoredProfile = await controller.prepare(profileName: "NEW")

            #expect(restoredProfile == nil)
            #expect(configurationStore.configuredDatabricksProfile == "OLD")
            #expect(!controller.isConfigured)
            await service.shutdown()
        }

        @Test
        func workspaceValidationBlocksNormalRequestsAndRestoresReadinessOnCancellation() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-databricks-readiness-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)
            let configURL = try locator.homeURL().appending(path: "config.toml")
            let originalConfiguration = Data("existing configuration".utf8)
            try originalConfiguration.write(to: configURL)
            let responder = WorkspaceSignInResponder(
                initialProfiles: #"{"profiles":[]}"#,
                signedInProfiles: """
                {"profiles":[
                    {"name":"Dahlia","host":"https://new.example.com","auth_type":"databricks-cli"}
                ]}
                """
            )
            let validationTransport = TestCodexAppServerTransport(mode: .blockFirstModelList)
            let configurationStore = TestCodexAccountConfigurationStore(
                configuredProvider: .databricks,
                configuredDatabricksProfile: "OLD"
            )
            let service = CodexAppServerService(
                transportFactory: { validationTransport },
                transportTimeout: .seconds(600),
                configurationReadiness: {
                    await MainActor.run {
                        configurationStore.configuredProviderRawValue == AIAccountProvider.databricks.rawValue
                            && configurationStore.configuredDatabricksProfile == "OLD"
                    }
                }
            )
            let controller = DatabricksAccountController(
                client: DatabricksCLIClient { await responder.run($0) },
                configurationManager: CodexConfigurationManager(homeLocator: locator),
                service: service,
                configurationStore: configurationStore
            )

            let signIn = Task {
                await controller.signIn(workspaceURL: "https://new.example.com", profileName: "Dahlia")
            }
            await validationTransport.waitUntilSent("model/list")

            #expect(configurationStore.configuredProviderRawValue.isEmpty)
            await #expect(throws: CodexConfigurationError.accountNotReady) {
                _ = try await service.models()
            }

            signIn.cancel()
            _ = await signIn.value

            #expect(FileManager.default.contents(atPath: configURL.path) == originalConfiguration)
            #expect(configurationStore.configuredProviderRawValue == AIAccountProvider.databricks.rawValue)
            #expect(configurationStore.configuredDatabricksProfile == "OLD")
            await service.shutdown()
        }

        @Test
        func terminalInstallResultIsForwardedWithoutLaunchingTerminalInTests() {
            let controller = DatabricksAccountController(
                cliInstaller: StubCLIInstaller(result: .commandCopied),
                configurationStore: TestCodexAccountConfigurationStore()
            )

            #expect(controller.installCLIInTerminal() == .commandCopied)
        }

        private actor ControllerAuthenticationResponder {
            private(set) var commands: [[String]] = []
            private let profileResponse: Data

            init(profileResponse: Data) {
                self.profileResponse = profileResponse
            }

            func run(_ arguments: [String]) -> DatabricksCLIClient.CommandOutput {
                commands.append(arguments)
                return switch commands.count {
                case 1:
                    .init(standardOutput: profileResponse, standardError: Data(), terminationStatus: 0)
                case 2:
                    .init(
                        standardOutput: Data(),
                        standardError: Data("cache: databricks OAuth is not configured for this host".utf8),
                        terminationStatus: 1
                    )
                default:
                    .init(
                        standardOutput: Data(),
                        standardError: Data("browser login timed out".utf8),
                        terminationStatus: 1
                    )
                }
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

        private actor RecoveringCLIResponder {
            private var isInstalled = false

            func install() {
                isInstalled = true
            }

            func run(_: [String]) throws -> DatabricksCLIClient.CommandOutput {
                guard isInstalled else { throw DatabricksCLIError.cliNotInstalled }
                let profiles = Data(
                    #"{"profiles":[{"name":"DEFAULT","host":"https://dbc.example.com","auth_type":"databricks-cli"}]}"#.utf8
                )
                return .init(standardOutput: profiles, standardError: Data(), terminationStatus: 0)
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
