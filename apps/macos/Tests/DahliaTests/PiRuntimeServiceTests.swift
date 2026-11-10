import DahliaRuntimeSupport
import Foundation
import os
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct PiRuntimeServiceTests {
        private static let schema = Data(#"{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]}"#.utf8)

        private static func runtime(
            provider: CodexRuntimeProvider = .local,
            models: [JSONValue] = [TestPiTransport.model(provider: "openai", id: "gpt-test")],
            summary: [JSONValue],
            transports: TestPiTransportLog = TestPiTransportLog()
        ) -> TestPiRuntime {
            TestPiRuntime(provider: provider) { options in
                let reply: TestPiTransport.Reply = { command in
                    guard let id = command["id"] else { return [] }
                    return [TestPiTransport.response(id: id)] + (command["type"]?.stringValue == "prompt" ? summary : [])
                }
                let transport = options.mode == .control
                    ? TestPiTransport(reply: TestPiRuntime.modelsReply(models))
                    : TestPiTransport(reply: reply)
                transports.append(transport)
                return transport
            }
        }

        private static func request(model: String? = "openai/gpt-test", inputs: [CodexAppServerInput]) -> CodexAppServerRequest {
            CodexAppServerRequest(
                model: model,
                requiresExactModel: true,
                reasoningEffort: "high",
                developerInstructions: "Summarize.",
                inputs: inputs,
                outputSchema: schema
            )
        }

        @Test
        func generateSendsModelSchemaAndNumberedImagesAndAcceptsFencedJSON() async throws {
            let transports = TestPiTransportLog()
            let pi = Self.runtime(summary: [
                TestPiTransport.assistantEnd("```json\n{\"a\":\"日本語😀\"}\n```"),
                TestPiTransport.settled(),
            ], transports: transports)

            let text = try await pi.service.generate(Self.request(inputs: [
                .text("<transcript>hi</transcript>"),
                .imageMetadata("<image_id>1</image_id>"),
                .imageDataURI("data:image/png;base64,AAEC"),
            ]))

            #expect(text == #"{"a":"日本語😀"}"#)
            let launch = try #require(pi.launches.all.first { $0.mode == .summary })
            #expect(launch.arguments.contains("--no-tools"))
            #expect(launch.arguments.contains("openai/gpt-test"))
            #expect(launch.arguments.contains("high"))
            #expect(launch.environment["PI_OUTPUT_STRICT_SCHEMA"] == "1")
            #expect(try launch.arguments[#require(launch.arguments.firstIndex(of: "--system-prompt")) + 1].contains(#""required":["a"]"#))
            let prompt = await transports.all[1].command("prompt")
            #expect(prompt["message"]?.stringValue?.contains("[Attached image 1] <image_id>1</image_id>") == true)
            #expect(prompt["images"]?.arrayValue?.first?.objectValue?["data"]?.stringValue == "AAEC")
            #expect(prompt["images"]?.arrayValue?.first?.objectValue?["mimeType"]?.stringValue == "image/png")
            #expect(await transports.allClosed())
        }

        @Test(arguments: ["I can't help with that.", "", "# Summary\nMarkdown"])
        func refusalsEmptyAndMarkdownRepliesFail(reply: String) async {
            let pi = Self.runtime(summary: [TestPiTransport.assistantEnd(reply), TestPiTransport.settled()])
            await #expect(throws: CodexAppServerError.self) {
                _ = try await pi.service.generate(Self.request(inputs: [.text("x")]))
            }
        }

        @Test
        func providerErrorsAndTruncationFail() async {
            let unauthorized = Self.runtime(summary: [
                TestPiTransport.assistantEnd("", stopReason: "error", errorMessage: "401 Unauthorized"),
                TestPiTransport.settled(),
            ])
            await #expect(throws: CodexAppServerError.notLoggedIn) {
                _ = try await unauthorized.service.generate(Self.request(inputs: [.text("x")]))
            }
            let truncated = Self.runtime(summary: [TestPiTransport.assistantEnd(#"{"a":"#, stopReason: "length"), TestPiTransport.settled()])
            await #expect(throws: CodexAppServerError.turnFailed("length")) {
                _ = try await truncated.service.generate(Self.request(inputs: [.text("x")]))
            }
        }

        struct TokenFailure: Error, Equatable {}

        @Test
        func failedTokenRefreshSurfacesItsErrorInsteadOfTheProviderFailure() async throws {
            let log = TestPiTransportLog()
            // Only the Databricks account uses the bridged gateways.
            let pi = TestPiRuntime(provider: .databricks(connectionID: .v7()), tokenResolver: { _ in throw TokenFailure() }) { options in
                let transport = options.mode == .control
                    ? TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "databricks", id: "gpt")]))
                    : TestPiTransport { command in
                        guard let id = command["id"] else { return [] }
                        guard command["type"]?.stringValue == "prompt" else { return [] }
                        return [
                            TestPiTransport.response(id: id),
                            TestPiTransport.bridgeRequest(
                                id: "ui-1",
                                method: "token",
                                payload: .object(["provider": .string("databricks")])
                            ),
                        ]
                    }
                log.append(transport)
                return transport
            }
            let generation = Task { try await pi.service.generate(Self.request(model: nil, inputs: [.text("x")])) }

            let summary = await log.transport(at: 1)
            let answer = await summary.command("extension_ui_response")
            #expect(answer["cancelled"] == .bool(true))
            await summary.emit(TestPiTransport.assistantEnd("", stopReason: "error", errorMessage: "Dahlia did not answer token"))
            await summary.emit(TestPiTransport.settled())

            await #expect(throws: CodexAppServerError.providerAuthenticationFailed(TokenFailure().localizedDescription)) {
                _ = try await generation.value
            }
        }

        @Test(arguments: [
            ("401 Unauthorized", true), ("HTTP error 401: invalid token", true), ("No API key found for provider openai", true),
            ("prompt is too long: 214013 tokens > 200000 maximum", false), ("429 rate limited", false),
        ])
        func authenticationFailuresAreRecognizedWithoutMatchingOtherNumbers(detail: String, expected: Bool) {
            #expect(PiRuntimeService.isAuthenticationFailure(detail) == expected)
        }

        @Test
        func textOnlyModelOmitsImagesAndClaudeGetsStrictSchema() async throws {
            let transports = TestPiTransportLog()
            let pi = Self.runtime(
                provider: .local,
                models: [TestPiTransport.model(provider: "anthropic", id: "claude-test", input: ["text"])],
                summary: [TestPiTransport.assistantEnd(#"{"a":"b"}"#), TestPiTransport.settled()],
                transports: transports
            )

            _ = try await pi.service.generate(Self.request(model: nil, inputs: [
                .text("t"), .imageMetadata("meta"), .imageDataURI("data:image/png;base64,AA"),
            ]))

            let prompt = await transports.all[1].command("prompt")
            #expect(prompt["images"] == nil)
            #expect(prompt["message"]?.stringValue == "t")
            let launch = try #require(pi.launches.all.first { $0.mode == .summary })
            #expect(launch.environment["PI_OUTPUT_STRICT_SCHEMA"] == "1")
            #expect(launch.arguments.contains("anthropic/claude-test"))
        }

        @Test
        func addedWorkspaceWithEveryModelOffLeavesPi() async throws {
            let workspace = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://dbc-1.cloud.databricks.com")))
            let choices = OSAllocatedUnfairLock(initialState: [String: Bool]())
            let pi = TestPiRuntime(modelChoices: { _ in choices.withLock { $0 } }, gatewayWorkspaces: { _ in [workspace] }) { _ in
                TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    guard command["message"]?.stringValue?.hasPrefix("/databricks-model-services") == true else {
                        return [TestPiTransport.response(id: id)]
                    }
                    let services = #"[{"name":"model-services/system.ai.gemini-3-8-flash","#
                        + #""supported_api_types":["gemini/v1/generateContent"],"capabilities":{"function_calling":true,"image_input":true}}]"#
                    return [TestPiTransport.response(id: id), TestPiTransport.notify("databricks:model_services \(services)")]
                }
            }
            let agentURL = try PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL).agentURL(for: .local)
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            let listed = {
                let data = try Data(contentsOf: agentURL.appending(path: "models.json"))
                let provider = try JSONDecoder().decode(JSONValue.self, from: data).objectValue?["providers"]?.objectValue?[workspace.id]
                return (provider?.objectValue?["models"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue }
            }

            // An added workspace starts with every model off.
            _ = try await pi.service.gatewayModels(for: .local, provider: workspace, forceRefresh: true)
            #expect(try listed().isEmpty)
            choices.withLock { $0["\(workspace.id)/system.ai.gemini-3-8-flash"] = true }
            try await pi.service.applyGatewayModelChoices(for: .local)
            #expect(try listed() == ["system.ai.gemini-3-8-flash"])

            // The last model of a workspace turned off leaves models.json, while the provider stays for its sign-in.
            choices.withLock { $0["\(workspace.id)/system.ai.gemini-3-8-flash"] = false }
            try await pi.service.applyGatewayModelChoices(for: .local)
            #expect(try listed().isEmpty)
        }

        @Test
        func gatewaysAreListedInTheBackgroundOncePerActivation() async throws {
            let workspace = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://dbc-1.cloud.databricks.com")))
            let listings = OSAllocatedUnfairLock(initialState: [String]())
            let pi = TestPiRuntime(gatewayWorkspaces: { _ in [workspace] }) { _ in
                TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    if command["type"]?.stringValue == "get_available_models" {
                        return [TestPiTransport.response(
                            id: id,
                            data: .object(["models": .array([TestPiTransport.model(provider: "openai", id: "gpt")])])
                        )]
                    }
                    guard let message = command["message"]?.stringValue, message.hasPrefix("/databricks-model-services") else {
                        return [TestPiTransport.response(id: id)]
                    }
                    listings.withLock { $0.append(message) }
                    return [
                        TestPiTransport.response(id: id),
                        TestPiTransport.notify(
                            #"databricks:model_services [{"name":"model-services/system.ai.kimi-k3","supported_api_types":["mlflow/v1/responses"]}]"#
                        ),
                    ]
                }
            }
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            let agentURL = try PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL).agentURL(for: .local)
            try Data(#"{"dbc-1.cloud.databricks.com":{}}"#.utf8).write(to: agentURL.appending(path: "auth.json"))

            _ = try await pi.service.models()
            await pi.service.gatewayRefresh(for: .local)?.value
            #expect(listings.withLock { $0 } == ["/databricks-model-services https://dbc-1.cloud.databricks.com"])
            #expect(PiProviderConfiguration.gatewayServices(agentURL: agentURL) == [
                workspace.id: [.object([
                    "name": .string("model-services/system.ai.kimi-k3"),
                    "supported_api_types": .array([.string("mlflow/v1/responses")]),
                ])],
            ])
            // A switch in Agents settings rewrites models.json from the saved list; the pickers' listing lists no gateway.
            try await pi.service.applyGatewayModelChoices(for: .local)
            _ = try await pi.service.models()
            await pi.service.gatewayRefresh(for: .local)?.value
            #expect(listings.withLock { $0.count } == 1)
            // Activating the account again lists its gateways again.
            try await pi.service.reloadConfiguration()
            _ = try await pi.service.models()
            await pi.service.gatewayRefresh(for: .local)?.value
            #expect(listings.withLock { $0.count } == 2)
        }

        @Test
        func theModelsTabJoinsAGatewayListingAlreadyRunning() async throws {
            let workspace = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://dbc-1.cloud.databricks.com")))
            let (listings, listed) = AsyncStream<(TestPiTransport, JSONValue)>.makeStream()
            let count = OSAllocatedUnfairLock(initialState: 0)
            let pi = TestPiRuntime(gatewayWorkspaces: { _ in [workspace] }) { _ in
                let current = OSAllocatedUnfairLock<TestPiTransport?>(initialState: nil)
                let transport = TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    if command["type"]?.stringValue == "get_available_models" {
                        return [TestPiTransport.response(
                            id: id,
                            data: .object(["models": .array([TestPiTransport.model(provider: "openai", id: "gpt")])])
                        )]
                    }
                    guard command["message"]?.stringValue?.hasPrefix("/databricks-model-services") == true,
                          let transport = current.withLock({ $0 })
                    else { return [TestPiTransport.response(id: id)] }
                    // The test answers the first two listings once the Models tab is waiting too; a tab that starts its
                    // own listing after the shared one ended is refused at once.
                    let listing = count.withLock { value -> Int in
                        value += 1
                        return value
                    }
                    guard listing <= 2 else {
                        return [TestPiTransport.response(id: id), TestPiTransport.notify("databricks:model_services_sign_in_required")]
                    }
                    listed.yield((transport, id))
                    return []
                }
                current.withLock { $0 = transport }
                return transport
            }
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            let agentURL = try PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL).agentURL(for: .local)
            try Data(#"{"dbc-1.cloud.databricks.com":{}}"#.utf8).write(to: agentURL.appending(path: "auth.json"))

            // The first listing after activation starts the background listing; the tab opens while it runs.
            _ = try await pi.service.models()
            var iterator = listings.makeAsyncIterator()
            let (transport, id) = try #require(await iterator.next())
            let tab = Task { try await pi.service.gatewayModels(for: .local, provider: workspace, forceRefresh: false) }
            let services = #"[{"name":"model-services/system.ai.kimi-k3","supported_api_types":["mlflow/v1/responses"]}]"#
            await transport.emit(TestPiTransport.response(id: id))
            await transport.emit(TestPiTransport.notify("databricks:model_services \(services)"))

            let models = try await tab.value
            #expect(models.map(\.id) == ["system.ai.kimi-k3"])
            await pi.service.gatewayRefresh(for: .local)?.value
            #expect(count.withLock { $0 } == 1)

            // A failed listing reaches every caller that joined it, so the tab shows the sign-in it needs.
            try await pi.service.reloadConfiguration()
            try FileManager.default.removeItem(at: agentURL.appending(path: "gateway-models.json"))
            _ = try await pi.service.models()
            let (failing, failingID) = try #require(await iterator.next())
            let failedTab = Task { try await pi.service.gatewayModels(for: .local, provider: workspace, forceRefresh: false) }
            await failing.emit(TestPiTransport.response(id: failingID))
            await failing.emit(TestPiTransport.notify("databricks:model_services_sign_in_required"))
            await #expect(throws: CodexAppServerError.notLoggedIn) { try await failedTab.value }
        }

        @Test
        func aListingSupersededByAnActivationSavesNothing() async throws {
            let workspace = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://dbc-1.cloud.databricks.com")))
            let (listings, listed) = AsyncStream<(TestPiTransport, JSONValue)>.makeStream()
            let pi = TestPiRuntime(gatewayWorkspaces: { _ in [workspace] }) { _ in
                let current = OSAllocatedUnfairLock<TestPiTransport?>(initialState: nil)
                let transport = TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    if command["type"]?.stringValue == "get_available_models" {
                        return [TestPiTransport.response(
                            id: id,
                            data: .object(["models": .array([TestPiTransport.model(provider: "openai", id: "gpt")])])
                        )]
                    }
                    guard command["message"]?.stringValue?.hasPrefix("/databricks-model-services") == true,
                          let transport = current.withLock({ $0 })
                    else { return [TestPiTransport.response(id: id)] }
                    listed.yield((transport, id))
                    return []
                }
                current.withLock { $0 = transport }
                return transport
            }
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            let agentURL = try PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL).agentURL(for: .local)
            try Data(#"{"dbc-1.cloud.databricks.com":{}}"#.utf8).write(to: agentURL.appending(path: "auth.json"))
            let answer = { (model: String) in
                TestPiTransport
                    .notify(
                        #"databricks:model_services [{"name":"model-services/system.ai.\#(model)","supported_api_types":["mlflow/v1/responses"]}]"#
                    )
            }
            var iterator = listings.makeAsyncIterator()

            // The first listing is held while the account is activated again and lists anew.
            _ = try await pi.service.models()
            let first = await pi.service.gatewayRefresh(for: .local)
            let (older, olderID) = try #require(await iterator.next())
            try await pi.service.reloadConfiguration()
            _ = try await pi.service.models()
            let (newer, newerID) = try #require(await iterator.next())
            await newer.emit(TestPiTransport.response(id: newerID))
            await newer.emit(answer("kimi-k3"))
            await pi.service.gatewayRefresh(for: .local)?.value
            // The older answer lands last and is discarded.
            await older.emit(TestPiTransport.response(id: olderID))
            await older.emit(answer("glm-5-3"))
            await first?.value

            let saved = PiProviderConfiguration.gatewayServices(agentURL: agentURL)[workspace.id]
            #expect(saved?.first?.objectValue?["name"] == .string("model-services/system.ai.kimi-k3"))
        }

        @Test
        func modelListingsAndSwitchesNeverWaitForAGateway() async throws {
            let account = CodexRuntimeProvider.databricks(connectionID: .v7())
            let workspaceURL = try #require(URL(string: "https://own.cloud.databricks.com"))
            let choices = ["databricks/system.ai.claude-opus-6": true]
            let pi = TestPiRuntime(provider: account, modelChoices: { _ in choices }) { _ in
                // The gateway never answers its listing.
                TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    if command["type"]?.stringValue == "get_available_models" {
                        return [TestPiTransport.response(
                            id: id,
                            data: .object(["models": .array([TestPiTransport.model(provider: "databricks", id: "system.ai.claude-haiku-5-5")])])
                        )]
                    }
                    return command["message"]?.stringValue?.hasPrefix("/databricks-model-services") == true ? [] : [TestPiTransport.response(id: id)]
                }
            }
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            let agentURL = try PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL).agentURL(for: account)
            try PiProviderConfiguration.write(
                PiProviderConfiguration.databricksProviders(
                    PiProviderConfiguration.databricksModels(workspaceURL: workspaceURL),
                    choices: [:],
                    workspaceURL: workspaceURL
                ),
                agentURL: agentURL
            )
            // The gateway answered with a model the bundle lacks in an earlier activation, and the user turned it on.
            try PiProviderConfiguration.saveGatewayServices([.object([
                "name": .string("model-services/system.ai.claude-opus-6"),
                "supported_api_types": .array([.string("anthropic/v1/messages")]),
            ])], providerID: "databricks", agentURL: agentURL)

            #expect(try await pi.service.models().map(\.model) == ["databricks/system.ai.claude-haiku-5-5"])
            try await pi.service.applyGatewayModelChoices(for: account)
            let data = try Data(contentsOf: agentURL.appending(path: "models.json"))
            let own = try JSONDecoder().decode(JSONValue.self, from: data).objectValue?["providers"]?.objectValue?["databricks"]
            #expect((own?.objectValue?["models"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue } == ["system.ai.claude-opus-6"])
            await pi.service.shutdown()
        }

        @Test
        func databricksAccountsOwnGatewayListsThroughPiWithItsBridgedSignIn() async throws {
            let account = CodexRuntimeProvider.databricks(connectionID: .v7())
            let own = try AgentMCPProvider.account(workspaceURL: #require(URL(string: "https://own.cloud.databricks.com")))
            let listings = OSAllocatedUnfairLock(initialState: [String]())
            let pi = TestPiRuntime(provider: account) { _ in
                TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    guard let message = command["message"]?.stringValue, message.hasPrefix("/databricks-model-services") else {
                        return [TestPiTransport.response(id: id)]
                    }
                    listings.withLock { $0.append(message) }
                    // A refused sign-in reads as sign-in required, which Agents settings shows as such.
                    return [TestPiTransport.response(id: id), TestPiTransport.notify("databricks:model_services_sign_in_required")]
                }
            }
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }

            await #expect(throws: CodexAppServerError.notLoggedIn) {
                try await pi.service.gatewayModels(for: account, provider: own, forceRefresh: true)
            }
            #expect(listings.withLock { $0 } == ["/databricks-model-services https://own.cloud.databricks.com --provider databricks"])
        }

        @Test
        func theAccountsOwnModelsComeBeforeAddedWorkspaces() async throws {
            let pi = TestPiRuntime(provider: .databricks(connectionID: .v7())) { _ in
                TestPiTransport(reply: TestPiRuntime.modelsReply([
                    TestPiTransport.model(provider: "dbc-1.cloud.databricks.com", id: "system.ai.claude-opus-5-5"),
                    TestPiTransport.model(provider: "databricks", id: "system.ai.claude-sonnet-5-5"),
                ]))
            }
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }

            // A saved model that is gone falls back to the first listed one, which is the account's own.
            let listed = try await pi.service.models()
            #expect(listed.map(\.model) == ["databricks/system.ai.claude-sonnet-5-5", "dbc-1.cloud.databricks.com/system.ai.claude-opus-5-5"])
            let request = CodexAppServerRequest(
                model: "databricks/system.ai.claude-haiku-5-5",
                developerInstructions: "",
                inputs: [],
                outputSchema: Data()
            )
            #expect(try PiRuntimeService.resolvedModel(for: request, in: listed).model == "databricks/system.ai.claude-sonnet-5-5")
        }

        @Test
        func listingThatStartedBeforeAModelChangeListsAgain() async throws {
            let log = TestPiTransportLog()
            let pi = TestPiRuntime { _ in
                // The first listing waits for the test's answer; later ones answer with the new list.
                let transport = log.all.isEmpty
                    ? TestPiTransport { $0["type"]?.stringValue == "get_available_models" ? [] : TestPiTransport.acknowledge($0) }
                    : TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "openai", id: "new")]))
                log.append(transport)
                return transport
            }
            let listing = Task { try await pi.service.models() }
            let first = await log.transport(at: 0)
            let id = try #require(await first.command("get_available_models")["id"])

            // A model switch or sign-in lands while Pi lists the old models.
            try await pi.service.reloadConfiguration()
            await first.emit(TestPiTransport.response(
                id: id,
                data: .object(["models": .array([TestPiTransport.model(provider: "openai", id: "old")])])
            ))

            #expect(try await listing.value.map(\.model) == ["openai/new"])
            #expect(try await pi.service.models().map(\.model) == ["openai/new"])
        }

        @Test(arguments: [
            ("openai/gpt-test", true), ("anthropic/claude-test", true), ("dahlia/any", true),
            ("databricks/system.ai.gpt-6-luna", true), ("databricks/system.ai.claude-opus-5-5", true),
            ("databricks/system.ai.gemini-4-argon", true),
            // Databricks's MLflow route serves these as OpenAI Responses without strict schema support.
            ("databricks/system.ai.glm-5-3", false), ("databricks/system.ai.kimi-k3", false),
            // A workspace added in Agents settings is named by its host.
            ("dbc-1.cloud.databricks.com/system.ai.claude-opus-5-5", true), ("dbc-1.cloud.databricks.com/system.ai.glm-5-3", false),
            ("other/system.ai.gpt-6-luna", false),
        ])
        func strictSchemaCoversOpenAIClaudeAndGeminiButNotTheMLflowRoute(model: String, expected: Bool) {
            #expect(PiRuntimeService.supportsStrictSchema(model: model) == expected)
        }

        @Test
        func modelsListTheAccountsSignedInProvidersAndDeriveEfforts() async throws {
            let models = [
                TestPiTransport.model(provider: "openai", id: "gpt-test"),
                TestPiTransport.model(provider: "google", id: "gemini"),
                TestPiTransport.model(
                    provider: "databricks",
                    id: "system.ai.claude",
                    thinkingLevelMap: .object(["off": .null, "minimal": .null, "xhigh": .string("xhigh")])
                ),
            ]
            let local = Self.runtime(provider: .local, models: models, summary: [])
            let databricks = TestPiRuntime(provider: .databricks(connectionID: .v7())) { _ in
                TestPiTransport(reply: TestPiRuntime.modelsReply(models))
            }

            #expect(try await local.service.models().map(\.model) == ["openai/gpt-test"])
            let gateway = try await databricks.service.models()
            #expect(gateway.map(\.model) == ["databricks/system.ai.claude"])
            #expect(gateway[0].supportedReasoningEfforts.map(\.reasoningEffort) == ["low", "medium", "high", "xhigh"])
            #expect(gateway[0].defaultReasoningEffort == "medium")
            #expect(try await local.service.accountStatus(for: .openai) == .init(isAuthenticated: true))
            #expect(try await local.service.accountStatus(for: .anthropic) == .init(isAuthenticated: false))
        }

        @Test(arguments: [false, true])
        func eachAccountListsOnlyItsOwnProviders(databricksAccount prefersDatabricks: Bool) async throws {
            let models = [
                TestPiTransport.model(provider: "openai", id: "gpt-6-luna"),
                TestPiTransport.model(provider: "databricks", id: "system.ai.gpt-6-luna"),
            ]
            let pi = TestPiRuntime(provider: prefersDatabricks ? .databricks(connectionID: .v7()) : .local) { _ in
                TestPiTransport(reply: TestPiRuntime.modelsReply(models))
            }

            let listed = try await pi.service.models()

            // The Local Account uses the subscriptions and a Databricks account its gateways, though Pi lists both.
            let expected = prefersDatabricks ? "databricks/system.ai.gpt-6-luna" : "openai/gpt-6-luna"
            #expect(listed.map(\.model) == [expected])
            #expect(PiRuntimeService.matchingModel("gpt-6-luna", in: listed)?.model == expected)
        }

        @Test
        func concurrentModelRequestsShareOneListingAndSignInListsAgain() async throws {
            let pi = TestPiRuntime { _ in
                TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    switch command["type"]?.stringValue {
                    case "get_available_models":
                        let models = [TestPiTransport.model(provider: "openai", id: "gpt-test")]
                        return [TestPiTransport.response(id: id, data: .object(["models": .array(models)]))]
                    case "prompt":
                        return [
                            TestPiTransport.notify("dahlia:auth_url https://auth.example.com/a"),
                            TestPiTransport.notify("dahlia:login_succeeded"),
                        ]
                    default:
                        return [TestPiTransport.response(id: id)]
                    }
                }
            }

            async let first = pi.service.models()
            async let second = pi.service.models()
            #expect(try await first == second)
            _ = try await pi.service.models()
            #expect(pi.launches.all.count(where: { $0.mode == .control }) == 1)

            try await pi.service.signIn(.anthropic) { _ in true }
            _ = try await pi.service.models()
            // The sign-in process and one new listing; the cache from before the sign-in is gone.
            #expect(pi.launches.all.count(where: { $0.mode == .control }) == 3)
        }

        @Test
        func anEmptyModelListIsListedAgainOnTheNextRequest() async throws {
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let pi = TestPiRuntime(provider: .dahlia(connectionID: .v7())) { _ in
                TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    let count = calls.withLock { value -> Int in
                        value += 1
                        return value
                    }
                    let models = count == 1 ? [] : [TestPiTransport.model(provider: "dahlia", id: "gpt")]
                    return [TestPiTransport.response(id: id, data: .object(["models": .array(models)]))]
                }
            }

            #expect(try await pi.service.models().isEmpty)
            #expect(try await pi.service.models().map(\.model) == ["dahlia/gpt"])
            #expect(try await pi.service.models().map(\.model) == ["dahlia/gpt"])
            #expect(calls.withLock { $0 } == 2)
        }

        @Test
        func signedOutSubscriptionHasNoModels() async {
            let pi = Self.runtime(models: [], summary: [])
            await #expect(throws: CodexAppServerError.notLoggedIn) {
                _ = try await pi.service.models()
            }
            #expect(await (try? pi.service.accountStatus(for: .openai)) == .init(isAuthenticated: false))
        }

        @Test
        func codexEraModelNamesMigrateBySuffixAndExactReferencesStayExact() throws {
            let models = [
                PiProviderConfiguration.codexModel([
                    "provider": .string("databricks"),
                    "id": .string("system.ai.claude"),
                    "input": .array([.string("text")]),
                ]),
                PiProviderConfiguration.codexModel(["provider": .string("databricks"), "id": .string("system.ai.gpt-6-luna")]),
            ].compactMap(\.self)
            func request(_ model: String, images: Bool = false, exact: Bool = false) -> CodexAppServerRequest {
                CodexAppServerRequest(
                    model: model,
                    requiresExactModel: exact,
                    requiresImageInput: images,
                    developerInstructions: "",
                    inputs: [],
                    outputSchema: Data()
                )
            }

            #expect(try PiRuntimeService.resolvedModel(for: request("gpt-6-luna"), in: models)
                .model == "databricks/system.ai.gpt-6-luna")
            #expect(try PiRuntimeService.resolvedModel(for: request("gpt-5.5"), in: models).model == "databricks/system.ai.claude")
            #expect(try PiRuntimeService.resolvedModel(for: request("gpt-5.5", images: true), in: models)
                .model == "databricks/system.ai.gpt-6-luna")
            #expect(try PiRuntimeService.resolvedModel(for: request("gpt-6-luna", exact: true), in: models)
                .model == "databricks/system.ai.gpt-6-luna")
            // Screenshot analysis requires its model: a missing one stays unavailable instead of using another model.
            for missing in ["openai/gone", "gpt-5.5"] {
                #expect(throws: CodexAppServerError.requestedModelUnavailable(missing)) {
                    try PiRuntimeService.resolvedModel(for: request(missing, exact: true), in: models)
                }
            }
            #expect(PiRuntimeService.matchingModel(" gpt-6-luna ", in: models)?.model == "databricks/system.ai.gpt-6-luna")
            #expect(PiRuntimeService.matchingModel("gpt-5.5", in: models) == nil)
            #expect(PiRuntimeService.matchingModel("openai/gpt-6-luna", in: models) == nil)
        }

        @Test
        func signInOpensPiAuthorizationURLAndWaitsForCompletion() async throws {
            let pi = TestPiRuntime { _ in
                TestPiTransport { command in
                    guard command["type"]?.stringValue == "prompt" else { return [] }
                    return [
                        TestPiTransport.notify("dahlia:auth_url https://auth.example.com/authorize?x=1"),
                        TestPiTransport.notify("dahlia:login_succeeded"),
                    ]
                }
            }
            let opened = OpenedURLs()

            try await pi.service.signIn(.anthropic) { url in
                opened.append(url)
                return true
            }

            #expect(opened.all == [URL(string: "https://auth.example.com/authorize?x=1")])
            let launch = try #require(pi.launches.all.first)
            #expect(UUID(uuidString: launch.environment["DAHLIA_PI_DEVICE_ID"] ?? "") != nil)
        }

        @Test
        func anAccountBeingLeftCannotStartPiButLocalSignInStillCan() async throws {
            let pi = TestPiRuntime { _ in TestPiTransport() }
            let cwd = FileManager.default.temporaryDirectory
            let databricks = CodexRuntimeProvider.databricks(connectionID: .v7())
            // The switch to Databricks has begun, so the Local Account's delayed work must not launch Pi now.
            pi.contextStore.beginActivation(databricks)

            await #expect(throws: CodexConfigurationError.providerChanged(CodexRuntimeProvider.local.displayName)) {
                try await pi.service.connect(.init(mode: .summary, cwd: cwd), provider: .local)
            }
            await #expect(throws: CodexConfigurationError.self) {
                try await pi.service.connect(.init(mode: .control, cwd: cwd), provider: .dahlia(connectionID: .v7()))
            }
            let signIn = try await pi.service.connect(.init(mode: .control, cwd: cwd), provider: .local)
            let summary = try await pi.service.connect(.init(mode: .summary, cwd: cwd), provider: databricks)
            await pi.service.close(signIn)
            await pi.service.close(summary)
        }

        @Test
        func signOutClosesLocalProcessesAndKeepsOtherAccounts() async throws {
            let log = TestPiTransportLog()
            let pi = TestPiRuntime { _ in
                let transport = TestPiTransport()
                log.append(transport)
                return transport
            }
            let cwd = FileManager.default.temporaryDirectory
            /// Each account's process starts while that account is open; switching does not close these test processes.
            func connect(_ provider: CodexRuntimeProvider) async throws -> PiRPCConnection {
                pi.contextStore.apply(provider)
                return try await pi.service.connect(.init(mode: .chat, cwd: cwd), provider: provider)
            }
            let dahlia = try await connect(.dahlia(connectionID: .v7()))
            let databricks = try await connect(.databricks(connectionID: .v7()))
            let local = try await connect(.local)

            try await pi.service.signOut(.openai)

            #expect(await !local.isOpen)
            #expect(await dahlia.isOpen)
            #expect(await databricks.isOpen)
            await pi.service.close(databricks)
            await pi.service.close(dahlia)
        }

        @Test
        func signInRejectsNonHTTPSURLsAndReportsFailure() async {
            for message in ["dahlia:auth_url file:///etc/passwd", "dahlia:login_failed denied"] {
                let pi = TestPiRuntime { _ in
                    TestPiTransport { command in
                        command["type"]?.stringValue == "prompt" ? [TestPiTransport.notify(message)] : []
                    }
                }
                await #expect(throws: CodexAppServerError.self) {
                    try await pi.service.signIn(.openai) { _ in true }
                }
            }
        }

        @Test
        func bridgeAnswersTokenRequestsOverStdin() async {
            let transport = TestPiTransport()
            let connection = PiRPCConnection(transport: transport) { method, payload in
                #expect(method == "token")
                #expect(payload.objectValue?["provider"]?.stringValue == "dahlia")
                return .string("secret")
            }
            await connection.start()

            await transport.emit(TestPiTransport.bridgeRequest(id: "ui-1", method: "token", payload: .object(["provider": .string("dahlia")])))
            let response = await transport.command("extension_ui_response")

            #expect(response["id"]?.stringValue == "ui-1")
            #expect(response["value"]?.stringValue == #""secret""#)
            await connection.close()
        }

        final class OpenedURLs: @unchecked Sendable {
            // Guarded by `lock`.
            private let lock = NSLock()
            private var storage: [URL] = []
            var all: [URL] { lock.withLock { storage } }
            func append(_ url: URL) { lock.withLock { storage.append(url) } }
        }
    }
#endif
