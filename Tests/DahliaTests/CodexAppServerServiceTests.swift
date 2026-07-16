import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Synchronization
    import Testing

    @MainActor
    struct CodexAppServerServiceTests {
        @Test
        func connectionIsInitializedOnceAndReused() async throws {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = CodexAppServerService(transportFactory: { transport })

            let first = try await service.models()
            let second = try await service.models(forceRefresh: true)

            #expect(first.map(\.model) == ["default-model"])
            #expect(second == first)
            let methods = await methodsSent(to: transport)
            #expect(methods.count(where: { $0 == "initialize" }) == 1)
            #expect(methods.count(where: { $0 == "model/list" }) == 2)
            await service.shutdown()
            #expect(await transport.isClosed)
        }

        @Test
        func bootstrapChecksAccountWithoutRefreshingToken() async throws {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = CodexAppServerService(transportFactory: { transport })

            try await service.start()

            let accountRead = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "account/read"
            })
            #expect(accountRead.objectValue?["params"] == .object(["refreshToken": .bool(false)]))
            await service.shutdown()
        }

        @Test
        func browserLoginUsesSupportedParametersAndBuffersImmediateCompletion() async throws {
            let transport = TestCodexAppServerTransport(mode: .loginCompletes)
            let service = CodexAppServerService(transportFactory: { transport })

            let initialStatus = try await service.accountStatus(forceRefresh: false)
            #expect(!initialStatus.isAuthenticated)

            let session = try await service.startChatGPTLogin()
            #expect(session.id == "login-1")
            #expect(session.authorizationURL == URL(string: "https://chatgpt.com/auth/test"))
            try await service.waitForLoginCompletion(loginID: session.id)

            let finalStatus = try await service.accountStatus(forceRefresh: true)
            #expect(finalStatus.isAuthenticated)
            let loginRequest = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "account/login/start"
            })
            #expect(loginRequest.objectValue?["params"] == .object([
                "appBrand": .string("codex"),
                "type": .string("chatgpt"),
                "useHostedLoginSuccessPage": .bool(true),
            ]))
            await service.shutdown()
        }

        @Test
        func cancellingBrowserLoginSendsCancelWithoutClosingSharedProcess() async throws {
            let transport = TestCodexAppServerTransport(mode: .loginBlocks)
            let service = CodexAppServerService(transportFactory: { transport })
            let session = try await service.startChatGPTLogin()
            let completion = Task {
                try await service.waitForLoginCompletion(loginID: session.id)
            }

            completion.cancel()
            await #expect(throws: CancellationError.self) {
                try await completion.value
            }
            await transport.waitUntilSent("account/login/cancel")

            #expect(await !(transport.isClosed))
            let status = try await service.accountStatus(forceRefresh: true)
            #expect(!status.isAuthenticated)
            await service.shutdown()
        }

        @Test
        func logoutUsesNullParamsAndClearsCachedAccount() async throws {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = CodexAppServerService(transportFactory: { transport })
            #expect(try await service.accountStatus(forceRefresh: false).isAuthenticated)

            try await service.logout()

            #expect(try await !service.accountStatus(forceRefresh: false).isAuthenticated)
            let logoutRequest = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "account/logout"
            })
            #expect(logoutRequest.objectValue?["params"] == .null)
            await service.shutdown()
        }

        @Test
        func signedOutGenerationFailsBeforeStartingThread() async {
            let transport = TestCodexAppServerTransport(mode: .signedOut)
            let service = CodexAppServerService(transportFactory: { transport })

            await #expect(throws: CodexAppServerError.notLoggedIn) {
                _ = try await service.generate(.init(
                    model: nil,
                    developerInstructions: "Summarize.",
                    inputs: [.text("Transcript")],
                    outputSchema: Data(#"{"type":"object"}"#.utf8)
                ))
            }

            #expect(await !methodsSent(to: transport).contains("thread/start"))
            await service.shutdown()
        }

        @Test
        func cancelledModelRequestDoesNotCloseHealthySharedProcess() async throws {
            let transport = TestCodexAppServerTransport(mode: .blockFirstModelList)
            let service = CodexAppServerService(transportFactory: { transport })
            let firstRequest = Task { try await service.models(forceRefresh: true) }

            await transport.waitUntilSent("model/list")
            firstRequest.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await firstRequest.value
            }

            let models = try await service.models(forceRefresh: true)
            #expect(models.map(\.model) == ["default-model"])
            #expect(await !(transport.isClosed))
            #expect(await (methodsSent(to: transport)).count(where: { $0 == "initialize" }) == 1)
            await service.shutdown()
        }

        @Test
        func requestTimeoutKeepsHealthySharedTransport() async throws {
            let transport = TestCodexAppServerTransport(mode: .blockFirstModelList)
            let service = CodexAppServerService(
                transportFactory: { transport },
                transportTimeout: .milliseconds(20)
            )

            await #expect(throws: CodexAppServerError.self) {
                _ = try await service.models(forceRefresh: true)
            }
            #expect(await !transport.isClosed)

            let models = try await service.models(forceRefresh: true)
            #expect(models.map(\.model) == ["default-model"])
            #expect(await (methodsSent(to: transport)).count(where: { $0 == "initialize" }) == 1)
            await service.shutdown()
        }

        @Test
        func lightweightRequestTimeoutDoesNotInterruptActiveSummary() async throws {
            let transport = TestCodexAppServerTransport(mode: .generationBlocks)
            let service = CodexAppServerService(transportFactory: { transport })
            let generation = Task {
                try await service.generate(.init(
                    model: nil,
                    developerInstructions: "Summarize.",
                    inputs: [.text("Transcript")],
                    outputSchema: Data(#"{"type":"object"}"#.utf8)
                ))
            }

            await service.waitUntilActiveTurnForTesting()
            await #expect(throws: CodexAppServerError.requestTimedOut("test/blocked")) {
                _ = try await service.request(method: "test/blocked", timeout: .milliseconds(20))
            }
            #expect(await !transport.isClosed)

            await transport.sendFromServer(.object([
                "method": .string("item/completed"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                    "item": .object([
                        "type": .string("agentMessage"),
                        "text": .string(#"{"status":"ok"}"#),
                    ]),
                ]),
            ]))
            await transport.sendFromServer(.object([
                "method": .string("turn/completed"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turn": .object([
                        "id": .string("turn-1"),
                        "status": .string("completed"),
                    ]),
                ]),
            ]))

            #expect(try await generation.value == #"{"status":"ok"}"#)
            #expect(await (methodsSent(to: transport)).count(where: { $0 == "initialize" }) == 1)
            await service.shutdown()
        }

        @Test
        func configurationReloadWaitsForActiveSummary() async throws {
            let first = TestCodexAppServerTransport(mode: .generationBlocks)
            let second = TestCodexAppServerTransport(mode: .models)
            let transports = Mutex([first, second])
            let launchCount = Mutex(0)
            let service = CodexAppServerService(transportFactory: {
                launchCount.withLock { $0 += 1 }
                return transports.withLock { $0.removeFirst() }
            })
            let generation = Task {
                try await service.generate(.init(
                    model: nil,
                    developerInstructions: "Summarize.",
                    inputs: [.text("Transcript")],
                    outputSchema: Data(#"{"type":"object"}"#.utf8)
                ))
            }

            await service.waitUntilActiveTurnForTesting()
            let reload = Task { try await service.reloadConfiguration() }
            await service.waitUntilConfigurationReloadIsWaitingForTesting()

            #expect(launchCount.withLock { $0 } == 1)
            #expect(await !first.isClosed)

            await first.sendFromServer(.object([
                "method": .string("item/completed"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                    "item": .object([
                        "type": .string("agentMessage"),
                        "text": .string(#"{"status":"ok"}"#),
                    ]),
                ]),
            ]))
            await first.sendFromServer(.object([
                "method": .string("turn/completed"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turn": .object([
                        "id": .string("turn-1"),
                        "status": .string("completed"),
                    ]),
                ]),
            ]))

            #expect(try await generation.value == #"{"status":"ok"}"#)
            try await reload.value
            #expect(launchCount.withLock { $0 } == 2)
            #expect(await first.isClosed)
            await service.shutdown()
        }

        @Test
        func modelListRequiresCurrentAccountConfigurationUnlessBypassed() async throws {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = CodexAppServerService(
                transportFactory: { transport },
                configurationReadiness: { false }
            )

            await #expect(throws: CodexConfigurationError.accountNotReady) {
                _ = try await service.models()
            }
            await #expect(throws: CodexConfigurationError.accountNotReady) {
                _ = try await service.generate(.init(
                    model: nil,
                    developerInstructions: "Summarize.",
                    inputs: [.text("Transcript")],
                    outputSchema: Data(#"{"type":"object"}"#.utf8)
                ))
            }
            #expect(await transport.messages().isEmpty)

            let models = try await service.models(bypassConfigurationCheck: true)
            #expect(models.map(\.model) == ["default-model"])
            await service.shutdown()
        }

        @Test
        func shutdownWaitsForCloseAndPermanentlyPreventsRestart() async throws {
            let blocked = TestCodexAppServerTransport(mode: .blockClose)
            let launchCount = Mutex(0)
            let service = CodexAppServerService(transportFactory: {
                launchCount.withLock { $0 += 1 }
                return blocked
            })
            try await service.start()

            let shutdown = Task { await service.shutdown() }
            await blocked.waitUntilCloseStarted()
            let restart = Task { try await service.start() }

            await blocked.finishClosing()
            await #expect(throws: CancellationError.self) {
                try await restart.value
            }
            await shutdown.value
            await #expect(throws: CancellationError.self) {
                try await service.start()
            }
            #expect(launchCount.withLock { $0 } == 1)
        }

        @Test
        func configurationReloadStartsAFreshConnection() async throws {
            let first = TestCodexAppServerTransport(mode: .models)
            let second = TestCodexAppServerTransport(mode: .models)
            let transports = Mutex([first, second])
            let launchCount = Mutex(0)
            let service = CodexAppServerService(transportFactory: {
                launchCount.withLock { $0 += 1 }
                return transports.withLock { $0.removeFirst() }
            })

            try await service.start()
            try await service.reloadConfiguration()

            #expect(launchCount.withLock { $0 } == 2)
            #expect(await first.isClosed)
            #expect(await !second.isClosed)
            #expect(try await service.models().map(\.model) == ["default-model"])
            await service.shutdown()
        }

        @Test
        func bootstrapCancellationClosesTransportAndCanRestart() async throws {
            let blocked = TestCodexAppServerTransport(mode: .blockInitialize)
            let replacement = TestCodexAppServerTransport(mode: .models)
            let transports = Mutex([blocked, replacement])
            let service = CodexAppServerService(transportFactory: {
                transports.withLock { available in available.removeFirst() }
            })
            let startup = Task { try await service.start() }

            await blocked.waitUntilSent("initialize")
            startup.cancel()
            await #expect(throws: CancellationError.self) {
                try await startup.value
            }
            #expect(await blocked.isClosed)

            #expect(try await service.models().map(\.model) == ["default-model"])
            #expect(await (methodsSent(to: replacement)).count(where: { $0 == "initialize" }) == 1)
            await service.shutdown()
        }

        @Test
        func responsesAreMatchedByIDWhenTheyArriveOutOfOrder() async throws {
            let transport = TestCodexAppServerTransport(mode: .outOfOrder)
            let service = CodexAppServerService(transportFactory: { transport })
            let first = Task { try await service.request(method: "test/first") }

            await transport.waitUntilSent("test/first")
            let second = Task { try await service.request(method: "test/second") }

            #expect(try await first.value == .string("first"))
            #expect(try await second.value == .string("second"))
            await service.shutdown()
        }

        @Test
        func approvalRequestsAreDeclinedAndUnknownRequestsReturnMethodNotFound() async throws {
            let transport = TestCodexAppServerTransport(mode: .serverRequests)
            let service = CodexAppServerService(transportFactory: { transport })

            try await service.start()
            await transport.waitUntilResponded(to: "approval-1")
            await transport.waitUntilResponded(to: "unknown-1")
            let messages = await transport.messages()
            let approval = try #require(messages.first {
                $0.objectValue?["id"] == .string("approval-1")
                    && $0.objectValue?["method"] == nil
            }?.objectValue)
            let unknown = try #require(messages.first {
                $0.objectValue?["id"] == .string("unknown-1")
                    && $0.objectValue?["method"] == nil
            }?.objectValue)

            #expect(approval["result"]?.objectValue?["decision"] == .string("decline"))
            #expect(unknown["error"]?.objectValue?["code"] == .number(-32601))
            await service.shutdown()
        }

        @Test
        func turnNotificationSubscriptionReceivesMessagesAndFinishes() async throws {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = CodexAppServerService(transportFactory: { transport })
            try await service.start()
            let notifications = await service.notifications(threadID: "thread-1", turnID: "turn-1")
            let collected = Task {
                var messages: [JSONValue] = []
                for try await message in notifications {
                    messages.append(message)
                }
                return messages
            }

            await transport.sendFromServer(.object([
                "method": .string("item/completed"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                    "item": .object(["type": .string("agentMessage"), "text": .string("done")]),
                ]),
            ]))
            await transport.sendFromServer(.object([
                "method": .string("turn/completed"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turn": .object(["id": .string("turn-1"), "status": .string("completed")]),
                ]),
            ]))

            #expect(try await collected.value.count == 2)
            await service.shutdown()
        }

        @Test
        func eofFailsAllPendingRequestsAndNextOperationRestarts() async throws {
            let crashed = TestCodexAppServerTransport(mode: .blockRequests)
            let replacement = TestCodexAppServerTransport(mode: .models)
            let transports = Mutex([crashed, replacement])
            let service = CodexAppServerService(transportFactory: {
                transports.withLock { available in available.removeFirst() }
            })
            let first = Task { try await service.request(method: "test/one") }
            let second = Task { try await service.request(method: "test/two") }

            await crashed.waitUntilSent("test/one")
            await crashed.waitUntilSent("test/two")
            await crashed.endOutput()

            await #expect(throws: CodexAppServerError.self) { try await first.value }
            await #expect(throws: CodexAppServerError.self) { try await second.value }
            #expect(await crashed.isClosed)
            #expect(try await service.models().map(\.model) == ["default-model"])
            await service.shutdown()
        }

        @Test
        func generationUsesEphemeralThreadAndStructuredOutput() async throws {
            let transport = TestCodexAppServerTransport(mode: .generationCompletes)
            let service = CodexAppServerService(transportFactory: { transport })

            let response = try await service.generate(.init(
                model: "default-model",
                developerInstructions: "Summarize.",
                inputs: [.text("Transcript")],
                outputSchema: Data(#"{"type":"object"}"#.utf8)
            ))

            #expect(response == #"{"status":"ok"}"#)
            let messages = await transport.messages()
            let threadParams = try #require(messages.first {
                $0.objectValue?["method"]?.stringValue == "thread/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(threadParams["ephemeral"] == .bool(true))
            #expect(threadParams["approvalPolicy"] == .string("never"))
            #expect(threadParams["sandbox"] == .string("read-only"))
            let threadConfig = try #require(threadParams["config"]?.objectValue)
            #expect(threadConfig["features.apps"] == .bool(false))
            #expect(threadConfig["features.plugins"] == .bool(false))
            #expect(threadConfig["mcp_oauth_credentials_store"] == .string("file"))
            #expect(threadConfig["model_reasoning_effort"] == .string("medium"))
            #expect(threadConfig["mcp_servers"] == .object([
                "docs": .object(["enabled": .bool(false)]),
                "local.server": .object(["enabled": .bool(false)]),
            ]))
            #expect(await (methodsSent(to: transport)).contains("config/read"))
            let turnParams = try #require(messages.first {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(turnParams["outputSchema"] == .object(["type": .string("object")]))
            #expect(await (methodsSent(to: transport)).contains("thread/unsubscribe"))
            await service.shutdown()
        }

        @Test
        func summaryThreadConfigUsesSelectedReasoningEffort() throws {
            let configReadResult = JSONValue.object([
                "config": .object([:]),
            ])

            let config = try #require(CodexAppServerService.summaryThreadConfig(
                from: configReadResult,
                reasoningEffort: "high"
            ).objectValue)

            #expect(config["model_reasoning_effort"] == .string("high"))
        }

        @Test
        func summaryThreadConfigRejectsUnscopedDahliaMCP() throws {
            let configReadResult = JSONValue.object([
                "config": .object([:]),
            ])
            let vaultID = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E6"))

            #expect(throws: CodexAppServerError.invalidProtocolResponse) {
                try CodexAppServerService.summaryThreadConfig(
                    from: configReadResult,
                    dahliaMCP: CodexAppServerDahliaMCPConfiguration(
                        executableURL: URL(fileURLWithPath: "/Applications/Dahlia.app/Contents/Helpers/dahlia-mcp"),
                        vaultID: vaultID,
                        allowedMeetingIDs: []
                    )
                )
            }
        }

        @Test
        func generationScopesDahliaMCPToConfiguredMeetings() async throws {
            let transport = TestCodexAppServerTransport(mode: .generationCompletes)
            let service = CodexAppServerService(transportFactory: { transport })
            let vaultID = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E6"))
            let firstMeetingID = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E7"))
            let secondMeetingID = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E8"))
            let executableURL = URL(fileURLWithPath: "/Applications/Dahlia.app/Contents/Helpers/dahlia-mcp")

            _ = try await service.generate(.init(
                model: nil,
                developerInstructions: "Summarize using the selected previous meetings.",
                inputs: [.text("Transcript")],
                outputSchema: Data(#"{"type":"object"}"#.utf8),
                dahliaMCP: CodexAppServerDahliaMCPConfiguration(
                    executableURL: executableURL,
                    vaultID: vaultID,
                    allowedMeetingIDs: [firstMeetingID, secondMeetingID]
                )
            ))

            let threadParams = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "thread/start"
            }?.objectValue?["params"]?.objectValue)
            let threadConfig = try #require(threadParams["config"]?.objectValue)
            #expect(threadConfig["mcp_servers"] == .object([
                "docs": .object(["enabled": .bool(false)]),
                "local.server": .object(["enabled": .bool(false)]),
                "dahlia": .object([
                    "args": .array([
                        .string("--vault-id"),
                        .string(vaultID.uuidString),
                        .string("--meeting-id"),
                        .string(firstMeetingID.uuidString),
                        .string("--meeting-id"),
                        .string(secondMeetingID.uuidString),
                    ]),
                    "command": .string(executableURL.path),
                    "enabled": .bool(true),
                ]),
            ]))
            let developerInstructions = try #require(threadParams["developerInstructions"]?.stringValue)
            #expect(developerInstructions.contains("You may call only the Dahlia get_meeting tool."))
            #expect(developerInstructions.contains("Do not call any other tool."))
            await service.shutdown()
        }

        @Test
        func unavailableSavedModelFallsBackToServerDefault() async throws {
            let transport = TestCodexAppServerTransport(mode: .generationCompletes)
            let service = CodexAppServerService(transportFactory: { transport })

            _ = try await service.generate(.init(
                model: "retired-model",
                developerInstructions: "Summarize.",
                inputs: [.text("Transcript")],
                outputSchema: Data(#"{"type":"object"}"#.utf8)
            ))

            let threadParams = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "thread/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(threadParams["model"] == .string("default-model"))
            await service.shutdown()
        }

        @Test
        func defaultTextOnlyModelDropsImagesAndStillGenerates() async throws {
            let transport = TestCodexAppServerTransport(mode: .textOnlyGenerationCompletes)
            let service = CodexAppServerService(transportFactory: { transport })

            let response = try await service.generate(.init(
                model: nil,
                developerInstructions: "Summarize.",
                inputs: [
                    .text("Transcript"),
                    .imageMetadata("<image_id>test</image_id>"),
                    .imageDataURI("data:image/jpeg;base64,AA=="),
                ],
                outputSchema: Data(#"{"type":"object"}"#.utf8)
            ))

            #expect(response == #"{"status":"ok"}"#)
            let turnParams = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            }?.objectValue?["params"]?.objectValue)
            let input = try #require(turnParams["input"]?.arrayValue)
            #expect(input.count == 1)
            #expect(input.first?.objectValue?["type"] == .string("text"))
            await service.shutdown()
        }

        @Test
        func structuredUnauthorizedTurnFailureRequiresLogin() async {
            let transport = TestCodexAppServerTransport(mode: .generationFailsUnauthorized)
            let service = CodexAppServerService(transportFactory: { transport })

            await #expect(throws: CodexAppServerError.notLoggedIn) {
                _ = try await service.generate(.init(
                    model: nil,
                    developerInstructions: "Summarize.",
                    inputs: [.text("Transcript")],
                    outputSchema: Data(#"{"type":"object"}"#.utf8)
                ))
            }
            await service.shutdown()
        }

        @Test
        func unrelatedUnauthorizedTextRemainsTurnFailure() async {
            let transport = TestCodexAppServerTransport(mode: .generationFailsMessageOnlyUnauthorized)
            let service = CodexAppServerService(transportFactory: { transport })

            await #expect(throws: CodexAppServerError.turnFailed("unauthorized while generating")) {
                _ = try await service.generate(.init(
                    model: nil,
                    developerInstructions: "Summarize.",
                    inputs: [.text("Transcript")],
                    outputSchema: Data(#"{"type":"object"}"#.utf8)
                ))
            }
            await service.shutdown()
        }

        @Test
        func structuredAuthenticationRPCErrorRequiresLogin() async {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = CodexAppServerService(transportFactory: { transport })

            await #expect(throws: CodexAppServerError.notLoggedIn) {
                _ = try await service.request(method: "test/auth")
            }
            await service.shutdown()
        }

        @Test
        func expectedCodexConfigurationErrorsAreNotReported() {
            #expect(!CaptionViewModel.shouldCaptureSummaryGenerationError(CodexAppServerError.notLoggedIn))
            #expect(!CaptionViewModel.shouldCaptureSummaryGenerationError(CodexAppServerError.helperNotBundled))
            #expect(!CaptionViewModel.shouldCaptureSummaryGenerationError(CodexConfigurationError.accountNotReady))
            #expect(!CaptionViewModel.shouldCaptureSummaryGenerationError(CancellationError()))
            #expect(!CaptionViewModel.shouldCaptureSummaryGenerationError(CodexAppServerError.turnInterrupted))
            #expect(!CaptionViewModel.shouldCaptureSummaryGenerationError(
                CodexAppServerError.requestTimedOut("summary")
            ))
            #expect(CaptionViewModel.shouldCaptureSummaryGenerationError(CodexAppServerError.processExited(nil)))
        }

        @Test
        func generationReusesAccountAndConfigReads() async throws {
            let transport = TestCodexAppServerTransport(mode: .generationCompletes)
            let service = CodexAppServerService(transportFactory: { transport })
            let request = CodexAppServerRequest(
                model: nil,
                developerInstructions: "Summarize.",
                inputs: [.text("Transcript")],
                outputSchema: Data(#"{"type":"object"}"#.utf8)
            )

            _ = try await service.generate(request)
            _ = try await service.generate(request)

            let methods = await methodsSent(to: transport)
            #expect(methods.count(where: { $0 == "account/read" }) == 1)
            #expect(methods.count(where: { $0 == "config/read" }) == 1)
            await service.shutdown()
        }

        @Test
        func loginCompletionInvalidatesCachedModels() async throws {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = CodexAppServerService(transportFactory: { transport })
            _ = try await service.models()

            await transport.sendFromServer(.object([
                "method": .string("account/login/completed"),
                "params": .object([
                    "error": .null,
                    "loginId": .string("login-2"),
                    "success": .bool(true),
                ]),
            ]))
            _ = try await service.accountStatus(forceRefresh: true)
            _ = try await service.models()

            #expect(await (methodsSent(to: transport)).count(where: { $0 == "model/list" }) == 2)
            await service.shutdown()
        }

        @Test
        func generationCancellationInterruptsAndUnsubscribesWithoutKillingProcess() async {
            let transport = TestCodexAppServerTransport(mode: .generationBlocks)
            let service = CodexAppServerService(transportFactory: { transport })
            let generation = Task {
                try await service.generate(.init(
                    model: nil,
                    developerInstructions: "Summarize.",
                    inputs: [.text("Transcript")],
                    outputSchema: Data(#"{"type":"object"}"#.utf8)
                ))
            }

            await transport.waitUntilSent("turn/start")
            await service.waitUntilActiveTurnForTesting()
            generation.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await generation.value
            }
            await transport.waitUntilSent("thread/unsubscribe")
            let methods = await methodsSent(to: transport)
            #expect(methods.count(where: { $0 == "turn/interrupt" }) == 1)
            #expect(methods.contains("thread/unsubscribe"))
            #expect(await !(transport.isClosed))
            await service.shutdown()
        }

        @Test
        func processExitCleanupDoesNotLaunchReplacementForUnsubscribe() async {
            let crashed = TestCodexAppServerTransport(mode: .generationBlocks)
            let replacement = TestCodexAppServerTransport(mode: .models)
            let transports = Mutex([crashed, replacement])
            let launchCount = Mutex(0)
            let service = CodexAppServerService(transportFactory: {
                launchCount.withLock { $0 += 1 }
                return transports.withLock { $0.removeFirst() }
            })
            let generation = Task {
                try await service.generate(.init(
                    model: nil,
                    developerInstructions: "Summarize.",
                    inputs: [.text("Transcript")],
                    outputSchema: Data(#"{"type":"object"}"#.utf8)
                ))
            }

            await service.waitUntilActiveTurnForTesting()
            await crashed.endOutput()
            await #expect(throws: CodexAppServerError.self) {
                _ = try await generation.value
            }

            #expect(launchCount.withLock { $0 } == 1)
            #expect(await (methodsSent(to: replacement)).isEmpty)
            await service.shutdown()
        }

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
            let service = CodexAppServerService(transportFactory: { transport })

            await #expect(throws: CodexAppServerError.self) {
                try await service.start()
            }
            #expect(await transport.isClosed)
        }

        @Test
        func modelSelectionPrefersSavedThenDefault() async {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = CodexAppServerService(transportFactory: { transport })
            let catalog = CodexModelCatalog(service: service)

            await catalog.load()

            #expect(catalog.resolvedSelection(current: " default-model ") == "default-model")
            #expect(catalog.resolvedSelection(current: "missing") == "default-model")
            #expect(catalog.selectionToPersist(current: "missing") == nil)
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
            let service = CodexAppServerService(transportFactory: { transport })
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

        private func methodsSent(to transport: TestCodexAppServerTransport) async -> [String] {
            await transport.messages().compactMap { $0.objectValue?["method"]?.stringValue }
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
