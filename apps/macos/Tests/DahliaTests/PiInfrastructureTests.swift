import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct PiInfrastructureTests {
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
        func processTransportPassesPrivateAgentDirectory() async throws {
            let expected = "/tmp/dahlia-pi-agent"
            let transport = try CodexAppServerProcessTransport(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '{\"dir\":\"%s\"}\\n' \"$PI_CODING_AGENT_DIR\""],
                environment: ["PI_CODING_AGENT_DIR": expected]
            )

            let line = try #require(await transport.receiveLine())
            let value = try JSONDecoder().decode(JSONValue.self, from: line)

            #expect(value.objectValue?["dir"]?.stringValue == expected)
            await transport.close()
        }

        @Test(.timeLimit(.minutes(1)))
        func closingAConnectionCancelsItsPendingBridgeAnswer() async throws {
            // A Databricks token request can be waiting on a browser login; closing Pi must release it.
            let transport = TestPiTransport { _ in [] }
            let (started, startedContinuation) = AsyncStream<Void>.makeStream()
            let (cancelled, cancelledContinuation) = AsyncStream<Void>.makeStream()
            let connection = PiRPCConnection(transport: transport) { _, _ in
                startedContinuation.yield()
                await withTaskCancellationHandler {
                    // Stands in for a browser login that never completes.
                    try? await Task.sleep(for: .seconds(3600))
                } onCancel: {
                    cancelledContinuation.yield()
                }
                throw CancellationError()
            }
            await connection.start()
            await transport.emit(TestPiTransport.bridgeRequest(id: "token-1", method: "token", payload: .object([:])))
            var startedIterator = started.makeAsyncIterator()
            _ = await startedIterator.next()

            await connection.close()

            var cancelledIterator = cancelled.makeAsyncIterator()
            _ = await cancelledIterator.next()
        }

        @Test
        func agentDirectoriesArePrivateAndSeparatedByAccount() throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-pi-agent-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let databricksID = UUID.v7()
            let locator = PiAgentDirectoryLocator(applicationSupportURL: rootURL)
            let connectionID = UUID.v7()

            let local = try locator.agentURL(for: .local)
            let account = try locator.agentURL(for: .dahlia(connectionID: connectionID))
            let databricks = try locator.agentURL(for: .databricks(connectionID: databricksID))
            let deviceID = try locator.deviceID()

            #expect(local == rootURL.appending(path: "Dahlia/accounts/local/pi", directoryHint: .isDirectory))
            #expect(databricks == rootURL.appending(
                path: "Dahlia/accounts/\(databricksID.uuidString.lowercased())/pi", directoryHint: .isDirectory
            ))
            #expect(account.path.hasSuffix("accounts/\(connectionID.uuidString.lowercased())/pi"))
            for url in [local, account, databricks] {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            }
            #expect(try locator.deviceID() == deviceID)
            let legacyHome = rootURL.appending(path: "Dahlia/CodexAccounts/\(connectionID.uuidString.lowercased())")
            try FileManager.default.createDirectory(at: legacyHome, withIntermediateDirectories: true)
            try locator.removeAccountDirectory(connectionID: connectionID)
            #expect(!FileManager.default.fileExists(atPath: account.deletingLastPathComponent().path))
            #expect(!FileManager.default.fileExists(atPath: legacyHome.path))
        }

        @Test
        func chatsBelongToTheAccountThatRanThem() throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appending(path: "dahlia-pi-sessions-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            let locator = PiAgentDirectoryLocator(applicationSupportURL: rootURL)
            let workspaceID = UUID.v7()
            let databricksID = UUID.v7()

            let local = try locator.sessionsURL(for: .local, workspaceID: workspaceID)
            let databricks = try locator.sessionsURL(for: .databricks(connectionID: databricksID), workspaceID: workspaceID)

            // The same workspace under another account starts with that account's own (empty) history.
            #expect(local == rootURL.appending(path: "Dahlia/accounts/local/pi/sessions/\(workspaceID.uuidString.lowercased())", directoryHint: .isDirectory))
            #expect(databricks.path.hasSuffix("accounts/\(databricksID.uuidString.lowercased())/pi/sessions/\(workspaceID.uuidString.lowercased())"))
            let attributes = try FileManager.default.attributesOfItem(atPath: databricks.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }

        @Test
        func modelSelectionPrefersSavedThenFirstAvailable() async {
            let pi = TestPiRuntime { _ in
                TestPiTransport(reply: TestPiRuntime.modelsReply([
                    TestPiTransport.model(provider: "openai", id: "default-model", thinkingLevelMap: .object(["off": .null, "minimal": .null])),
                    TestPiTransport.model(provider: "openai", id: "gpt-6-luna"),
                ]))
            }
            let catalog = CodexModelCatalog(service: pi.service)

            await catalog.load()

            #expect(catalog.resolvedSelection(current: " openai/default-model ") == "openai/default-model")
            #expect(catalog.resolvedSelection(current: "gpt-6-luna") == "openai/gpt-6-luna")
            #expect(catalog.resolvedSelection(current: "missing") == "openai/default-model")
            #expect(catalog.selectionToPersist(current: "missing") == "openai/default-model")
            #expect(catalog.selectionToPersist(current: "") == "openai/default-model")
            #expect(catalog.effortOptions(modelID: "openai/default-model").map(\.reasoningEffort) == ["low", "medium", "high"])
            #expect(catalog.resolvedEffort(current: "", modelID: "openai/default-model") == "medium")
            #expect(catalog.resolvedEffort(current: "high", modelID: "openai/default-model") == "high")
            #expect(catalog.resolvedEffort(current: "max", modelID: "openai/default-model") == "medium")
            #expect(catalog.resolvedEffort(current: "high", modelID: "missing") == nil)
        }

        @Test
        func databricksAndDahliaModelsBecomePiProviders() throws {
            let databricks = try PiProviderConfiguration.databricksProviders(
                workspaceURL: #require(URL(string: "https://example.cloud.databricks.com"))
            )
            #expect(Set(databricks.keys) == Set(PiProviderConfiguration.databricksProviderIDs))
            let provider = try #require(databricks["databricks"]?.objectValue)
            #expect(provider["authHeader"] == .bool(true))
            // Each model keeps its own gateway route, now on the workspace's host.
            let routes = Dictionary(
                (provider["models"]?.arrayValue ?? []).compactMap(\.objectValue).map {
                    ($0["id"]?.stringValue ?? "", $0["baseUrl"]?.stringValue ?? "")
                },
                uniquingKeysWith: { first, _ in first }
            )
            #expect(routes["system.ai.claude-opus-5-5"] == "https://example.cloud.databricks.com/ai-gateway/anthropic")
            #expect(routes["system.ai.gpt-6-luna"] == "https://example.cloud.databricks.com/ai-gateway/codex/v1")
            #expect(routes["system.ai.kimi-k3-1-pro"] == "https://example.cloud.databricks.com/ai-gateway/mlflow/v1")
            #expect(routes["system.ai.gemini-3-8-flash"] == "https://example.cloud.databricks.com/ai-gateway/gemini/v1beta")
            #expect(routes.keys.allSatisfy { !$0.contains("grok") && !$0.contains("deepseek") })

            let catalog = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            {"data":[{"id":"gpt-6-sol","display_name":"GPT 6 Sol"}],
             "models":[{"slug":"gpt-6-sol","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}],"input_modalities":["text"]}]}
            """#.utf8))
            let dahlia = try PiProviderConfiguration.dahliaProvider(
                baseURL: #require(URL(string: "https://dahlia.example/api/v1")),
                catalog: catalog
            )
            let model = try #require(dahlia["dahlia"]?.objectValue?["models"]?.arrayValue?.first?.objectValue)
            #expect(model["name"]?.stringValue == "GPT 6 Sol")
            #expect(model["input"] == .array([.string("text")]))
            let converted = try #require(PiProviderConfiguration.codexModel(model.merging(["provider": .string("dahlia")]) { $1 }))
            #expect(converted.supportedReasoningEfforts.map(\.reasoningEffort) == ["low", "high"])
            #expect(!converted.supportsImages)
        }

        @Test
        func emptyCatalogDoesNotReplaceSavedEffort() {
            let catalog = CodexModelCatalog()
            #expect(catalog.resolvedEffort(current: "high", modelID: "missing") == nil)
        }

        @Test
        func cancelledInitialCatalogLoadCanBeRetried() async {
            let log = TestPiTransportLog()
            let pi = TestPiRuntime { _ in
                let transport = TestPiTransport { _ in [] }
                log.append(transport)
                return transport
            }
            let catalog = CodexModelCatalog(service: pi.service)
            let load = Task { await catalog.load(forceRefresh: true) }

            _ = await log.transport(at: 0).command("get_available_models")
            load.cancel()
            await load.value

            #expect(catalog.models.isEmpty)
            #expect(catalog.errorMessage == nil)
            #expect(catalog.canRetry)
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
    }
#endif
