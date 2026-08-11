import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct DatabricksAccountControllerTests {
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
            #expect(AppSettings.isCodexAccountConfigurationCurrent(
                selectedProvider: .databricks,
                selectedDatabricksProfile: "DEFAULT",
                configuredProviderRawValue: configurationStore.configuredProviderRawValue,
                configuredDatabricksProfile: configurationStore.configuredDatabricksProfile
            ))
            #expect(!AppSettings.isCodexAccountConfigurationCurrent(
                selectedProvider: .databricks,
                selectedDatabricksProfile: "OTHER",
                configuredProviderRawValue: configurationStore.configuredProviderRawValue,
                configuredDatabricksProfile: configurationStore.configuredDatabricksProfile
            ))
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
    }
#endif
