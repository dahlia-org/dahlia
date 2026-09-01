import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexAppServerInfrastructureTests {
        @Test
        func processTransportDrainsStderrAndReadsFragmentedJSONLines() async throws {
            let command = "dd if=/dev/zero bs=32768 count=1 >&2 2>/dev/null; "
                + "printf '{\\\"one\\\":1}\\n'; printf '{\\\"two\\\":2}'; printf '\\n'"
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", command]
            )

            let first = try #require(await transport.receiveLine())
            let second = try #require(await transport.receiveLine())

            #expect(String(bytes: first, encoding: .utf8) == #"{"one":1}"#)
            #expect(String(bytes: second, encoding: .utf8) == #"{"two":2}"#)
            await transport.close()
        }

        @Test
        func processTransportPassesDedicatedCodexHome() async throws {
            let expectedHome = "/tmp/dahlia-codex-home"
            let command = "printf '{\"home\":\"%s\"}\\n' \"$CODEX_HOME\""
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", command],
                environment: ["CODEX_HOME": expectedHome]
            )

            let line = try #require(await transport.receiveLine())
            let value = try JSONDecoder().decode(JSONValue.self, from: line)

            #expect(value.objectValue?["home"]?.stringValue == expectedHome)
            await transport.close()
        }

        @Test
        func applicationSupportLocatorCreatesPrivateDedicatedHome() throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-codex-home-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL)

            let homeURL = try locator.homeURL()
            let attributes = try FileManager.default.attributesOfItem(atPath: homeURL.path)

            let expectedURL = rootURL
                .appending(path: "Dahlia", directoryHint: .isDirectory)
                .appending(path: "Codex", directoryHint: .isDirectory)
            #expect(homeURL == expectedURL)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["DAHLIA_CODEX_INTEGRATION_TEST"] == "1"))
        func bundledCodexAccountReadCompletes() async throws {
            let executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: ".build/codex-helper/codex")
            let testEnvironment = try dedicatedCodexEnvironment()
            defer { try? FileManager.default.removeItem(at: testEnvironment.rootURL) }
            let service = CodexAppServerService(
                transportFactory: {
                    try CodexAppServerProcessTransport(
                        executableURL: executableURL,
                        environment: testEnvironment.environment
                    )
                }
            )

            do {
                let status = try await service.accountStatus()
                #expect(status.requiresOpenAIAuth || status.canUseCodex)
            } catch {
                await service.shutdown()
                throw error
            }
            await service.shutdown()
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["DAHLIA_CODEX_INTEGRATION_TEST"] == "1"))
        func bundledCodexSummaryThreadStartsWithMCPDisabled() async throws {
            let executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: ".build/codex-helper/codex")
            let testEnvironment = try dedicatedCodexEnvironment()
            defer { try? FileManager.default.removeItem(at: testEnvironment.rootURL) }
            let service = CodexAppServerService(
                transportFactory: {
                    try CodexAppServerProcessTransport(
                        executableURL: executableURL,
                        environment: testEnvironment.environment
                    )
                }
            )
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appending(
                    path: "dahlia-codex-thread-test-" + UUID().uuidString,
                    directoryHint: .isDirectory
                )
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            do {
                let configResult = try await service.request(method: "config/read")
                let result = try await service.request(
                    method: "thread/start",
                    params: .object([
                        "approvalPolicy": .string("never"),
                        "config": CodexAppServerService.summaryThreadConfig(from: configResult),
                        "cwd": .string(temporaryDirectory.path),
                        "developerInstructions": .string("Do not call tools."),
                        "ephemeral": .bool(true),
                        "sandbox": .string("read-only"),
                    ])
                )
                let threadID = try #require(result.objectValue?["thread"]?.objectValue?["id"]?.stringValue)
                _ = try await service.request(
                    method: "thread/unsubscribe",
                    params: .object(["threadId": .string(threadID)])
                )
            } catch {
                await service.shutdown()
                throw error
            }
            await service.shutdown()
        }

        @Test
        func invalidJSONClosesConnection() async {
            let transport = TestCodexAppServerTransport(mode: .invalidInitializeResponse)
            let service = makeTestCodexAppServerService(transportFactory: { transport })

            await #expect(throws: CodexAppServerError.self) {
                try await service.start()
            }
            #expect(await transport.isClosed)
        }

        @Test
        func modelSelectionPrefersSavedThenDefault() async {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let catalog = CodexModelCatalog(service: service)

            await catalog.load()

            #expect(catalog.resolvedSelection(current: " default-model ") == "default-model")
            #expect(catalog.resolvedSelection(current: "missing") == "default-model")
            #expect(catalog.selectionToPersist(current: "missing") == "default-model")
            #expect(catalog.selectionToPersist(current: "") == "default-model")
            #expect(catalog.effortOptions(modelID: "default-model").map(\.reasoningEffort) == [
                "low",
                "medium",
                "high",
            ])
            #expect(catalog.resolvedEffort(current: "", modelID: "default-model") == "medium")
            #expect(catalog.resolvedEffort(current: "high", modelID: "default-model") == "high")
            #expect(catalog.resolvedEffort(current: "unsupported", modelID: "default-model") == "medium")
            #expect(catalog.resolvedEffort(current: "high", modelID: "missing") == nil)
            await service.shutdown()
        }

        @Test
        func emptyCatalogDoesNotReplaceSavedEffort() {
            let catalog = CodexModelCatalog()
            #expect(catalog.resolvedEffort(current: "high", modelID: "missing") == nil)
        }

        @Test
        func cancelledInitialCatalogLoadCanBeRetried() async {
            let transport = TestCodexAppServerTransport(mode: .blockFirstModelList)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let catalog = CodexModelCatalog(service: service)
            let load = Task { await catalog.load(forceRefresh: true) }

            await transport.waitUntilSent("model/list")
            load.cancel()
            await load.value

            #expect(catalog.models.isEmpty)
            #expect(catalog.errorMessage == nil)
            #expect(catalog.canRetry)
            await service.shutdown()
        }

        @Test
        func missingInputModalitiesDoNotSilentlyDisableImages() {
            let model = CodexModel(
                id: "model",
                model: "model",
                displayName: "Model",
                description: "",
                hidden: false,
                isDefault: true,
                supportedReasoningEfforts: [],
                defaultReasoningEffort: "medium",
                inputModalities: nil
            )
            #expect(model.supportsImages)
        }

        private func dedicatedCodexEnvironment() throws -> (environment: [String: String], rootURL: URL) {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-codex-integration-\(UUID().uuidString)", directoryHint: .isDirectory)
            let homeURL = try ApplicationSupportCodexHomeLocator(applicationSupportURL: rootURL).homeURL()
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = homeURL.path
            return (environment, rootURL)
        }
    }
#endif
