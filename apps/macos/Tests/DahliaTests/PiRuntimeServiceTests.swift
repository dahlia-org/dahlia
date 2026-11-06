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
            #expect(launch.environment["DAHLIA_PI_STRICT_SCHEMA"] == "1")
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
        func textOnlyModelOmitsImagesAndClaudeSkipsStrictSchema() async throws {
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
            #expect(launch.environment["DAHLIA_PI_STRICT_SCHEMA"] == nil)
            #expect(launch.arguments.contains("anthropic/claude-test"))
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
            let databricks = TestPiRuntime(provider: .databricks(connectionID: .v7())) { _ in TestPiTransport(reply: TestPiRuntime.modelsReply(models)) }

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
            let pi = TestPiRuntime(provider: prefersDatabricks ? .databricks(connectionID: .v7()) : .local) { _ in TestPiTransport(reply: TestPiRuntime.modelsReply(models)) }

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
                        return [TestPiTransport.notify("dahlia:auth_url https://auth.example.com/a"), TestPiTransport.notify("dahlia:login_succeeded")]
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
        func signOutClosesLocalProcessesAndKeepsOtherAccounts() async throws {
            let log = TestPiTransportLog()
            let pi = TestPiRuntime { _ in
                let transport = TestPiTransport()
                log.append(transport)
                return transport
            }
            let cwd = FileManager.default.temporaryDirectory
            let local = try await pi.service.connect(.init(mode: .chat, cwd: cwd), provider: .local)
            let dahlia = try await pi.service.connect(.init(mode: .chat, cwd: cwd), provider: .dahlia(connectionID: .v7()))
            let databricks = try await pi.service.connect(.init(mode: .chat, cwd: cwd), provider: .databricks(connectionID: .v7()))

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
