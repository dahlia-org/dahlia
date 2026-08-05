import DahliaRuntimeSupport
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Synchronization
    import Testing

    @MainActor
    // Protocol lifecycle scenarios share test doubles and are kept in one auditable suite.
    // swiftlint:disable:next type_body_length
    struct CodexAppServerServiceTests {
        private actor CompletionGate {
            private var isOpen = false
            private var continuation: CheckedContinuation<Void, Never>?

            func wait() async {
                if isOpen { return }
                await withCheckedContinuation { continuation = $0 }
            }

            func open() {
                isOpen = true
                continuation?.resume()
                continuation = nil
            }
        }

        @Test
        func connectionIsInitializedOnceAndReused() async throws {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = makeTestCodexAppServerService(transportFactory: { transport })

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
            let service = makeTestCodexAppServerService(transportFactory: { transport })

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
            let service = makeTestCodexAppServerService(transportFactory: { transport })

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
            let service = makeTestCodexAppServerService(transportFactory: { transport })
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
            let service = makeTestCodexAppServerService(transportFactory: { transport })
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
            let service = makeTestCodexAppServerService(transportFactory: { transport })

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
            let service = makeTestCodexAppServerService(transportFactory: { transport })
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
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = makeTestCodexAppServerService(transportFactory: { transport })

            await #expect(throws: CodexAppServerError.requestTimedOut("test/blocked")) {
                _ = try await service.request(method: "test/blocked", timeout: .milliseconds(20))
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
            let service = makeTestCodexAppServerService(transportFactory: { transport })
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
            let service = makeTestCodexAppServerService(transportFactory: {
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
            let service = makeTestCodexAppServerService(
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
            let service = makeTestCodexAppServerService(transportFactory: {
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
            let service = makeTestCodexAppServerService(transportFactory: {
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
        func browserLoginReloadsConfigurationBeforeGeneration() async throws {
            let first = TestCodexAppServerTransport(mode: .models)
            let second = TestCodexAppServerTransport(mode: .generationCompletes)
            let transports = Mutex([first, second])
            let launchCount = Mutex(0)
            let preparationCount = Mutex(0)
            let service = makeTestCodexAppServerService(
                transportFactory: {
                    launchCount.withLock { $0 += 1 }
                    return transports.withLock { $0.removeFirst() }
                },
                providerAuthenticationPreparation: { _ in
                    preparationCount.withLock { $0 += 1 }
                    return true
                }
            )
            try await service.start()

            let result = try await service.generate(.init(
                model: nil,
                developerInstructions: "Summarize.",
                inputs: [.text("Transcript")],
                outputSchema: Data(#"{"type":"object"}"#.utf8)
            ))

            #expect(result == #"{"status":"ok"}"#)
            #expect(preparationCount.withLock { $0 } == 1)
            #expect(launchCount.withLock { $0 } == 2)
            #expect(await first.isClosed)
            await service.shutdown()
        }

        @Test
        func concurrentRequestsShareProviderAuthenticationPreparation() async throws {
            let first = TestCodexAppServerTransport(mode: .models)
            let second = TestCodexAppServerTransport(mode: .models)
            let transports = Mutex([first, second])
            let preparationCount = Mutex(0)
            let preparationStarted = AsyncStream.makeStream(of: Void.self)
            let releasePreparation = AsyncStream.makeStream(of: Void.self)
            let service = makeTestCodexAppServerService(
                transportFactory: { transports.withLock { $0.removeFirst() } },
                providerAuthenticationPreparation: { _ in
                    preparationCount.withLock { $0 += 1 }
                    preparationStarted.continuation.yield()
                    for await _ in releasePreparation.stream {
                        break
                    }
                    return true
                }
            )
            try await service.start()

            let firstPreparation = Task { try await service.prepareProviderAuthentication() }
            for await _ in preparationStarted.stream {
                break
            }
            let secondPreparation = Task { try await service.prepareProviderAuthentication() }
            await Task.yield()
            releasePreparation.continuation.yield()

            try await firstPreparation.value
            try await secondPreparation.value
            #expect(preparationCount.withLock { $0 } == 1)
            #expect(await first.isClosed)
            await service.shutdown()
        }

        @Test
        func cancellingOneAuthenticationWaiterReturnsWithoutCancellingSharedPreparation() async throws {
            let firstTransport = TestCodexAppServerTransport(mode: .models)
            let secondTransport = TestCodexAppServerTransport(mode: .models)
            let transports = Mutex([firstTransport, secondTransport])
            let preparationCount = Mutex(0)
            let firstFinished = Mutex(false)
            let preparationStarted = AsyncStream.makeStream(of: Void.self)
            let releasePreparation = AsyncStream.makeStream(of: Void.self)
            let service = makeTestCodexAppServerService(
                transportFactory: { transports.withLock { $0.removeFirst() } },
                providerAuthenticationPreparation: { _ in
                    preparationCount.withLock { $0 += 1 }
                    preparationStarted.continuation.yield()
                    for await _ in releasePreparation.stream {
                        break
                    }
                    return true
                }
            )
            try await service.start()

            let first = Task {
                defer { firstFinished.withLock { $0 = true } }
                try await service.prepareProviderAuthentication()
            }
            for await _ in preparationStarted.stream {
                break
            }
            let second = Task { try await service.prepareProviderAuthentication() }
            #expect(await pollUntil(timeout: .seconds(10)) {
                await service.providerAuthenticationWaiterCountForTesting == 2
            })

            first.cancel()
            #expect(await pollUntil(timeout: .seconds(10)) { firstFinished.withLock { $0 } })
            #expect(preparationCount.withLock { $0 } == 1)

            releasePreparation.continuation.yield()
            await #expect(throws: CancellationError.self) { try await first.value }
            try await second.value
            #expect(preparationCount.withLock { $0 } == 1)
            await service.shutdown()
        }

        @Test
        func cancellingOnlyAuthenticationWaiterCancelsUnderlyingPreparation() async throws {
            let transport = TestCodexAppServerTransport(mode: .models)
            let preparationCancelled = Mutex(false)
            let preparationStarted = AsyncStream.makeStream(of: Void.self)
            let service = makeTestCodexAppServerService(
                transportFactory: { transport },
                providerAuthenticationPreparation: { _ in
                    preparationStarted.continuation.yield()
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch is CancellationError {
                        preparationCancelled.withLock { $0 = true }
                        throw CancellationError()
                    }
                    return true
                }
            )
            try await service.start()

            let preparation = Task { try await service.prepareProviderAuthentication() }
            for await _ in preparationStarted.stream {
                break
            }
            preparation.cancel()

            await #expect(throws: CancellationError.self) { try await preparation.value }
            #expect(await pollUntil(timeout: .seconds(10)) { preparationCancelled.withLock { $0 } })
            #expect(await !transport.isClosed)
            await service.shutdown()
        }

        @Test
        func replacementAuthenticationWaitsForCancelledPreparationToFinish() async throws {
            let transport = TestCodexAppServerTransport(mode: .models)
            let preparationCount = Mutex(0)
            let preparationStarted = AsyncStream.makeStream(of: Void.self)
            let cancellationObserved = AsyncStream.makeStream(of: Void.self)
            let cancellationCompletion = CompletionGate()
            let service = makeTestCodexAppServerService(
                transportFactory: { transport },
                providerAuthenticationPreparation: { _ in
                    let attempt = preparationCount.withLock { count in
                        count += 1
                        return count
                    }
                    guard attempt == 1 else { return false }
                    preparationStarted.continuation.yield()
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch is CancellationError {
                        cancellationObserved.continuation.yield()
                        await cancellationCompletion.wait()
                        throw CancellationError()
                    }
                    return false
                }
            )
            try await service.start()

            let cancelled = Task { try await service.prepareProviderAuthentication() }
            for await _ in preparationStarted.stream {
                break
            }
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            for await _ in cancellationObserved.stream {
                break
            }

            let replacement = Task { try await service.prepareProviderAuthentication() }
            await Task.yield()
            #expect(preparationCount.withLock { $0 } == 1)

            await cancellationCompletion.open()
            try await replacement.value
            #expect(preparationCount.withLock { $0 } == 2)
            #expect(await !transport.isClosed)
            await service.shutdown()
        }

        @Test
        func failedLoginAttemptKeepsReloadRequiredForNextPreparation() async throws {
            let first = TestCodexAppServerTransport(mode: .models)
            let second = TestCodexAppServerTransport(mode: .models)
            let transports = Mutex([first, second])
            let preparationCount = Mutex(0)
            let service = makeTestCodexAppServerService(
                transportFactory: { transports.withLock { $0.removeFirst() } },
                providerAuthenticationPreparation: { authenticationMayChange in
                    let attempt = preparationCount.withLock { count in
                        count += 1
                        return count
                    }
                    if attempt == 1 {
                        await authenticationMayChange()
                        throw CodexAppServerError.notLoggedIn
                    }
                    return false
                }
            )
            try await service.start()

            await #expect(throws: CodexAppServerError.notLoggedIn) {
                try await service.prepareProviderAuthentication()
            }
            try await service.prepareProviderAuthentication()

            #expect(preparationCount.withLock { $0 } == 2)
            #expect(await first.isClosed)
            #expect(await !second.isClosed)
            await service.shutdown()
        }

        @Test
        func configurationReloadWaitsForActiveChatTurn() async throws {
            let first = TestCodexAppServerTransport(mode: .generationBlocks)
            let second = TestCodexAppServerTransport(mode: .models)
            let transports = Mutex([first, second])
            let launchCount = Mutex(0)
            let service = makeTestCodexAppServerService(transportFactory: {
                launchCount.withLock { $0 += 1 }
                return transports.withLock { $0.removeFirst() }
            })
            let turn = try await service.startChatTurn(
                threadID: "thread-1",
                params: .object([
                    "input": .array([.object(["type": .string("text"), "text": .string("Hi")])]),
                    "threadId": .string("thread-1"),
                ])
            )
            let consumption = Task {
                for try await _ in turn.notifications {}
            }

            let reload = Task { try await service.reloadConfiguration() }
            await service.waitUntilChatTurnReloadIsWaitingForTesting()
            #expect(launchCount.withLock { $0 } == 1)
            #expect(await !first.isClosed)

            await first.sendFromServer(.object([
                "method": .string("turn/completed"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turn": .object([
                        "id": .string(turn.turnID),
                        "status": .string("completed"),
                    ]),
                ]),
            ]))

            try await consumption.value
            try await reload.value
            #expect(launchCount.withLock { $0 } == 2)
            #expect(await first.isClosed)
            await service.shutdown()
        }

        @Test
        func summaryAdmissionWaitsForReloadThatIsDrainingChat() async throws {
            let first = TestCodexAppServerTransport(mode: .generationBlocks)
            let second = TestCodexAppServerTransport(mode: .generationCompletes)
            let transports = Mutex([first, second])
            let configurationReadCount = Mutex(0)
            let configurationReadStarted = AsyncStream.makeStream(of: Void.self)
            let releaseConfigurationRead = AsyncStream.makeStream(of: Void.self)
            let service = makeTestCodexAppServerService(
                transportFactory: { transports.withLock { $0.removeFirst() } },
                configurationReadiness: {
                    let readCount = configurationReadCount.withLock { count in
                        count += 1
                        return count
                    }
                    guard readCount == 1 else { return true }
                    configurationReadStarted.continuation.yield()
                    for await _ in releaseConfigurationRead.stream {
                        break
                    }
                    return true
                }
            )
            let chatTurn = try await service.startChatTurn(
                threadID: "chat-thread",
                params: .object([
                    "input": .array([.object(["type": .string("text"), "text": .string("Hi")])]),
                    "threadId": .string("chat-thread"),
                ])
            )
            let chatConsumption = Task {
                for try await _ in chatTurn.notifications {}
            }
            let summary = Task {
                try await service.generate(.init(
                    model: nil,
                    developerInstructions: "Summarize.",
                    inputs: [.text("Transcript")],
                    outputSchema: Data(#"{"type":"object"}"#.utf8)
                ))
            }
            for await _ in configurationReadStarted.stream {
                break
            }

            let reload = Task { try await service.reloadConfiguration() }
            await service.waitUntilChatTurnReloadIsWaitingForTesting()
            releaseConfigurationRead.continuation.yield()
            await Task.yield()
            #expect(await !methodsSent(to: first).contains("thread/start"))

            await first.sendFromServer(.object([
                "method": .string("turn/completed"),
                "params": .object([
                    "threadId": .string("chat-thread"),
                    "turn": .object([
                        "id": .string(chatTurn.turnID),
                        "status": .string("completed"),
                    ]),
                ]),
            ]))

            try await chatConsumption.value
            try await reload.value
            #expect(try await summary.value == #"{"status":"ok"}"#)
            #expect(await first.isClosed)
            #expect(await methodsSent(to: second).contains("thread/start"))
            await service.shutdown()
        }

        @Test
        func bootstrapCancellationClosesTransportAndCanRestart() async throws {
            let blocked = TestCodexAppServerTransport(mode: .blockInitialize)
            let replacement = TestCodexAppServerTransport(mode: .models)
            let transports = Mutex([blocked, replacement])
            let service = makeTestCodexAppServerService(transportFactory: {
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
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let first = Task { try await service.request(method: "test/first") }

            await transport.waitUntilSent("test/first")
            let second = Task { try await service.request(method: "test/second") }
            await transport.waitUntilSent("test/second")

            #expect(try await first.value == .string("first"))
            #expect(try await second.value == .string("second"))
            await service.shutdown()
        }

        @Test
        func approvalRequestsAreDeclinedAndUnknownRequestsReturnMethodNotFound() async throws {
            let transport = TestCodexAppServerTransport(mode: .serverRequests)
            let service = makeTestCodexAppServerService(transportFactory: { transport })

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
        func chatApprovalRequestsReachSubscribersAndAreDeclinedWhenTheTurnCompletes() async throws {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            try await service.start()
            let turn = try await service.startChatTurn(
                threadID: "thread-1",
                params: .object(["threadId": .string("thread-1")])
            )
            let collected = Task {
                var methods: [String] = []
                for try await message in turn.notifications {
                    if let method = message.objectValue?["method"]?.stringValue {
                        methods.append(method)
                    }
                }
                return methods
            }

            await transport.sendFromServer(.object([
                "id": .string("approval-1"),
                "method": .string("item/commandExecution/requestApproval"),
                "params": .object([
                    "command": .string("ls"),
                    "itemId": .string("item-1"),
                    "threadId": .string("thread-1"),
                    "turnId": .string(turn.turnID),
                ]),
            ]))
            await transport.sendFromServer(.object([
                "method": .string("turn/completed"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turn": .object([
                        "id": .string(turn.turnID),
                        "status": .string("completed"),
                    ]),
                ]),
            ]))
            await transport.waitUntilResponded(to: "approval-1")

            #expect(try await collected.value == [
                "item/commandExecution/requestApproval",
                "turn/completed",
            ])
            let approval = try #require(await transport.messages().first {
                $0.objectValue?["id"] == .string("approval-1")
                    && $0.objectValue?["method"] == nil
            }?.objectValue)
            #expect(approval["result"]?.objectValue?["decision"] == .string("decline"))
            await service.shutdown()
        }

        @Test
        func cancellingTurnSubscriptionCancelsUnconsumedApproval() async throws {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let turn = try await service.startChatTurn(
                threadID: "thread-1",
                params: .object(["threadId": .string("thread-1")])
            )
            let collected = Task {
                for try await _ in turn.notifications {}
            }

            await transport.sendFromServer(.object([
                "id": .string("approval-1"),
                "method": .string("item/commandExecution/requestApproval"),
                "params": .object([
                    "command": .string("ls"),
                    "itemId": .string("item-1"),
                    "threadId": .string("thread-1"),
                    "turnId": .string(turn.turnID),
                ]),
            ]))
            #expect(await pollUntil {
                await service.hasPendingApprovalForTesting("s:approval-1")
            })

            collected.cancel()
            _ = try? await collected.value
            await transport.waitUntilResponded(to: "approval-1")

            let approval = try #require(await transport.messages().first {
                $0.objectValue?["id"] == .string("approval-1")
                    && $0.objectValue?["method"] == nil
            }?.objectValue)
            #expect(approval["result"]?.objectValue?["decision"] == .string("cancel"))
            await service.shutdown()
        }

        @Test
        func chatApprovalDecisionUsesTheOriginalRequestIdentifier() async throws {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            try await service.start()
            let turn = try await service.startChatTurn(
                threadID: "thread-1",
                params: .object(["threadId": .string("thread-1")])
            )
            // Responds from inside the subscription so the stream is never abandoned early,
            // which would cancel the request before the decision is sent.
            let responded = Task {
                for try await message in turn.notifications {
                    guard message.objectValue?["method"]?.stringValue == "item/fileChange/requestApproval",
                          let requestID = message.objectValue?["id"],
                          let approvalID = CodexAppServerService.approvalID(for: requestID)
                    else { continue }
                    await service.respondToApproval(id: approvalID, decision: .acceptForSession)
                }
            }

            await transport.sendFromServer(.object([
                "id": .number(41),
                "method": .string("item/fileChange/requestApproval"),
                "params": .object([
                    "itemId": .string("item-1"),
                    "threadId": .string("thread-1"),
                    "turnId": .string(turn.turnID),
                ]),
            ]))
            await transport.waitUntilResponded(to: "41")
            await transport.sendFromServer(.object([
                "method": .string("turn/completed"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turn": .object([
                        "id": .string(turn.turnID),
                        "status": .string("completed"),
                    ]),
                ]),
            ]))
            try await responded.value

            let approval = try #require(await transport.messages().first {
                $0.objectValue?["id"] == .number(41) && $0.objectValue?["method"] == nil
            }?.objectValue)
            #expect(approval["result"]?.objectValue?["decision"] == .string("acceptForSession"))
            await service.shutdown()
        }

        @Test
        func cancelledTurnStartCancelsEarlyApprovalAndDiscardsBufferedMessages() async throws {
            let transport = TestCodexAppServerTransport(mode: .blockTurnStart)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let start = Task {
                try await service.startChatTurn(
                    threadID: "thread-1",
                    params: .object(["threadId": .string("thread-1")])
                )
            }
            await transport.waitUntilSent("turn/start")
            await transport.sendFromServer(.object([
                "id": .string("approval-1"),
                "method": .string("item/fileChange/requestApproval"),
                "params": .object([
                    "grantRoot": .string("/tmp/outside-workspace"),
                    "itemId": .string("item-1"),
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                ]),
            ]))
            #expect(await pollUntil {
                await service.hasPendingApprovalForTesting("s:approval-1")
            })

            start.cancel()
            await #expect(throws: CancellationError.self) {
                try await start.value
            }
            await transport.waitUntilResponded(to: "approval-1")
            let approval = try #require(await transport.messages().first {
                $0.objectValue?["id"] == .string("approval-1")
                    && $0.objectValue?["method"] == nil
            }?.objectValue)
            #expect(approval["result"]?.objectValue?["decision"] == .string("cancel"))

            await transport.sendFromServer(.object([
                "id": .string("approval-late"),
                "method": .string("item/fileChange/requestApproval"),
                "params": .object([
                    "itemId": .string("item-late"),
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                ]),
            ]))
            await transport.waitUntilResponded(to: "approval-late")
            let lateApproval = try #require(await transport.messages().first {
                $0.objectValue?["id"] == .string("approval-late")
                    && $0.objectValue?["method"] == nil
            }?.objectValue)
            #expect(lateApproval["result"]?.objectValue?["decision"] == .string("cancel"))

            let notifications = await service.notifications(threadID: "thread-1", turnID: "turn-1")
            let collected = Task {
                var methods: [String] = []
                for try await message in notifications {
                    if let method = message.objectValue?["method"]?.stringValue {
                        methods.append(method)
                    }
                }
                return methods
            }
            await transport.sendFromServer(.object([
                "method": .string("turn/completed"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turn": .object([
                        "id": .string("turn-1"),
                        "status": .string("interrupted"),
                    ]),
                ]),
            ]))
            #expect(try await collected.value == ["turn/completed"])
            await service.shutdown()
        }

        @Test
        func cancelledTurnStartInterruptsTurnDiscoveredFromBufferedNotification() async throws {
            let transport = TestCodexAppServerTransport(mode: .blockTurnStart)
            let clock = DiscoveredChatTurnStopTestClock()
            let service = makeTestCodexAppServerService(
                transportFactory: { transport },
                clock: clock
            )
            let start = Task {
                try await service.startChatTurn(
                    threadID: "thread-1",
                    params: .object(["threadId": .string("thread-1")])
                )
            }
            await transport.waitUntilSent("turn/start")
            await transport.sendFromServer(.object([
                "method": .string("item/started"),
                "params": .object([
                    "item": .object([
                        "id": .string("item-1"),
                        "type": .string("agentMessage"),
                    ]),
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                ]),
            ]))
            #expect(await pollUntil {
                await service.hasBufferedTurnMessagesForTesting(threadID: "thread-1", turnID: "turn-1")
            })

            start.cancel()
            await #expect(throws: CancellationError.self) {
                try await start.value
            }
            await transport.waitUntilSent("turn/interrupt")
            let interrupt = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "turn/interrupt"
            }?.objectValue?["params"]?.objectValue)
            #expect(interrupt["threadId"] == .string("thread-1"))
            #expect(interrupt["turnId"] == .string("turn-1"))
            #expect(await service.hasDiscoveredChatTurnStopForTesting(
                threadID: "thread-1",
                turnID: "turn-1"
            ))

            await transport.sendFromServer(.object([
                "method": .string("turn/completed"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turn": .object([
                        "id": .string("turn-1"),
                        "status": .string("interrupted"),
                    ]),
                ]),
            ]))
            #expect(await pollUntil {
                await !(service.hasDiscoveredChatTurnStopForTesting(
                    threadID: "thread-1",
                    turnID: "turn-1"
                ))
            })
            await clock.fireAllSleeps()
            #expect(await !transport.isClosed)
            await service.shutdown()
        }

        @Test
        func discoveredTurnInterruptTimeoutResetsConnection() async throws {
            let transport = TestCodexAppServerTransport(mode: .blockTurnStart)
            let clock = DiscoveredChatTurnStopTestClock()
            let service = makeTestCodexAppServerService(
                transportFactory: { transport },
                clock: clock
            )
            let start = Task {
                try await service.startChatTurn(
                    threadID: "thread-1",
                    params: .object(["threadId": .string("thread-1")])
                )
            }
            await transport.waitUntilSent("turn/start")
            await transport.sendFromServer(.object([
                "method": .string("item/started"),
                "params": .object([
                    "item": .object([
                        "id": .string("item-1"),
                        "type": .string("agentMessage"),
                    ]),
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                ]),
            ]))
            #expect(await pollUntil {
                await service.hasBufferedTurnMessagesForTesting(threadID: "thread-1", turnID: "turn-1")
            })

            start.cancel()
            await #expect(throws: CancellationError.self) {
                try await start.value
            }
            await transport.waitUntilSent("turn/interrupt")
            await clock.fireAllSleeps()

            #expect(await pollUntil { await transport.isClosed })
            await service.shutdown()
        }

        @Test
        func cancelledTurnStartInterruptsTurnDiscoveredFromLateResponse() async throws {
            let transport = TestCodexAppServerTransport(mode: .blockTurnStart)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let start = Task {
                try await service.startChatTurn(
                    threadID: "thread-1",
                    params: .object(["threadId": .string("thread-1")])
                )
            }
            await transport.waitUntilSent("turn/start")

            start.cancel()
            await #expect(throws: CancellationError.self) {
                try await start.value
            }
            await transport.completeBlockedTurnStart(turnID: "late-turn")
            await transport.waitUntilSent("turn/interrupt")
            let interrupt = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "turn/interrupt"
            }?.objectValue?["params"]?.objectValue)
            #expect(interrupt["threadId"] == .string("thread-1"))
            #expect(interrupt["turnId"] == .string("late-turn"))
            await service.shutdown()
        }

        @Test
        func cancelledTurnStartInterruptsTurnDiscoveredFromLateNotification() async throws {
            let transport = TestCodexAppServerTransport(mode: .blockTurnStart)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let start = Task {
                try await service.startChatTurn(
                    threadID: "thread-1",
                    params: .object(["threadId": .string("thread-1")])
                )
            }
            await transport.waitUntilSent("turn/start")

            start.cancel()
            await #expect(throws: CancellationError.self) {
                try await start.value
            }
            await transport.sendFromServer(.object([
                "method": .string("item/started"),
                "params": .object([
                    "item": .object([
                        "id": .string("item-late"),
                        "type": .string("agentMessage"),
                    ]),
                    "threadId": .string("thread-1"),
                    "turnId": .string("late-turn"),
                ]),
            ]))

            await transport.waitUntilSent("turn/interrupt")
            let interrupt = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "turn/interrupt"
            }?.objectValue?["params"]?.objectValue)
            #expect(interrupt["threadId"] == .string("thread-1"))
            #expect(interrupt["turnId"] == .string("late-turn"))
            await service.shutdown()
        }

        @Test
        func lateApprovalAfterSubscriberClosesIsCancelled() async throws {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let turn = try await service.startChatTurn(
                threadID: "thread-1",
                params: .object(["threadId": .string("thread-1")])
            )
            let collected = Task {
                for try await _ in turn.notifications {}
            }
            #expect(await pollUntil {
                await service.hasTurnSubscriberForTesting(
                    threadID: "thread-1",
                    turnID: turn.turnID
                )
            })
            collected.cancel()
            _ = try? await collected.value
            #expect(await pollUntil {
                await !(service.hasTurnSubscriberForTesting(
                    threadID: "thread-1",
                    turnID: turn.turnID
                ))
            })

            await transport.sendFromServer(.object([
                "id": .string("approval-late"),
                "method": .string("item/commandExecution/requestApproval"),
                "params": .object([
                    "command": .string("touch late"),
                    "itemId": .string("item-late"),
                    "threadId": .string("thread-1"),
                    "turnId": .string(turn.turnID),
                ]),
            ]))
            await transport.waitUntilResponded(to: "approval-late")

            let response = try #require(await transport.messages().first {
                $0.objectValue?["id"] == .string("approval-late")
                    && $0.objectValue?["method"] == nil
            }?.objectValue)
            #expect(response["result"]?.objectValue?["decision"] == .string("cancel"))
            #expect(await !(service.hasPendingApprovalForTesting("s:approval-late")))
            await service.shutdown()
        }

        @Test
        func approvalResponseWriteFailureStopsConnection() async throws {
            let transport = TestCodexAppServerTransport(mode: .models, failsApprovalResponses: true)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let turn = try await service.startChatTurn(
                threadID: "thread-1",
                params: .object(["threadId": .string("thread-1")])
            )
            let collected = Task {
                for try await _ in turn.notifications {}
            }
            await transport.sendFromServer(.object([
                "id": .string("approval-write-fails"),
                "method": .string("item/commandExecution/requestApproval"),
                "params": .object([
                    "command": .string("ls"),
                    "itemId": .string("item-1"),
                    "threadId": .string("thread-1"),
                    "turnId": .string(turn.turnID),
                ]),
            ]))
            #expect(await pollUntil {
                await service.hasPendingApprovalForTesting("s:approval-write-fails")
            })

            await service.respondToApproval(id: "s:approval-write-fails", decision: .accept)

            #expect(await transport.isClosed)
            #expect(await !(service.hasPendingApprovalForTesting("s:approval-write-fails")))
            _ = try? await collected.value
            await service.shutdown()
        }

        @Test
        func turnNotificationSubscriptionReceivesMessagesAndFinishes() async throws {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
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
            let service = makeTestCodexAppServerService(transportFactory: {
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
            let service = makeTestCodexAppServerService(transportFactory: { transport })

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
            #expect(threadConfig["skills.bundled.enabled"] == .bool(false))
            #expect(threadConfig["skills.include_instructions"] == .bool(false))
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
        func developmentChatConfigRoutesMCPToTheDevelopmentDatabaseProfile() throws {
            let configReadResult = JSONValue.object([
                "config": .object([:]),
            ])
            let vaultID = try #require(UUID(uuidString: "019E61FD-B5D6-7A04-AC25-4B820FE951E6"))
            let executableURL = URL(fileURLWithPath: "/Applications/Dahlia Dev.app/Contents/Helpers/dahlia-mcp")

            let config = try #require(CodexAppServerService.chatThreadConfig(
                from: configReadResult,
                helperURL: executableURL,
                vaultID: vaultID,
                runtimeProfile: .development
            ).objectValue)
            let server = try #require(config["mcp_servers"]?.objectValue?["dahlia"])

            #expect(config["features.tool_call_mcp_elicitation"] == .bool(false))
            #expect(server == .object([
                "args": .array([
                    .string("DAHLIA_RUNTIME_PROFILE=development"),
                    .string(executableURL.path),
                    .string("--vault-id"),
                    .string(vaultID.uuidString),
                    .string("--write"),
                ]),
                "command": .string("/usr/bin/env"),
                "enabled": .bool(true),
            ]))
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
            let service = makeTestCodexAppServerService(transportFactory: { transport })
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
            let service = makeTestCodexAppServerService(transportFactory: { transport })

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
            let service = makeTestCodexAppServerService(transportFactory: { transport })

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
            let service = makeTestCodexAppServerService(transportFactory: { transport })

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
        func expectedProviderAuthenticationFailurePreservesDetailWithoutReporting() async {
            let transport = TestCodexAppServerTransport(mode: .generationFailsExpectedProviderAuthentication)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let detail = """
            unexpected status 401 Unauthorized: {"error_code":401,"message":"Credential was not sent or was of an unsupported type for this API."}
            """
            let expectedError = CodexAppServerError.providerAuthenticationFailed(detail)
            let paddedTurnError: [String: JSONValue] = ["message": .string("\n \(detail)\n")]

            #expect(CodexAppServerService.isExpectedProviderAuthenticationTurnError(paddedTurnError))
            await #expect(throws: expectedError) {
                _ = try await service.generate(.init(
                    model: nil,
                    developerInstructions: "Summarize.",
                    inputs: [.text("Transcript")],
                    outputSchema: Data(#"{"type":"object"}"#.utf8)
                ))
            }
            #expect(expectedError.localizedDescription == L10n.codexRequestFailed(detail))
            #expect(!CaptionViewModel.shouldCaptureSummaryGenerationError(expectedError))
            await service.shutdown()
        }

        @Test
        func unrelatedHTTPUnauthorizedTurnFailureRemainsReportable() async {
            let transport = TestCodexAppServerTransport(mode: .generationFailsOtherHTTPUnauthorized)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let detail = """
            unexpected status 401 Unauthorized: {"error":"An upstream tool rejected its credentials."}
            """
            let expectedError = CodexAppServerError.turnFailed(detail)

            await #expect(throws: expectedError) {
                _ = try await service.generate(.init(
                    model: nil,
                    developerInstructions: "Summarize.",
                    inputs: [.text("Transcript")],
                    outputSchema: Data(#"{"type":"object"}"#.utf8)
                ))
            }
            #expect(CaptionViewModel.shouldCaptureSummaryGenerationError(expectedError))
            await service.shutdown()
        }

        @Test
        func unrelatedUnauthorizedTextRemainsTurnFailure() async {
            let transport = TestCodexAppServerTransport(mode: .generationFailsMessageOnlyUnauthorized)
            let service = makeTestCodexAppServerService(transportFactory: { transport })

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
            let service = makeTestCodexAppServerService(transportFactory: { transport })

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
            let service = makeTestCodexAppServerService(transportFactory: { transport })
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
            let service = makeTestCodexAppServerService(transportFactory: { transport })
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
            let service = makeTestCodexAppServerService(transportFactory: { transport })
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
            let service = makeTestCodexAppServerService(transportFactory: {
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

        private func methodsSent(to transport: TestCodexAppServerTransport) async -> [String] {
            await transport.messages().compactMap { $0.objectValue?["method"]?.stringValue }
        }
    }

    private actor DiscoveredChatTurnStopTestClock: CodexAppServerClock {
        private var firesImmediately = false
        private var sleeps: [UUID: CheckedContinuation<Void, any Error>] = [:]

        func sleep(for _: Duration) async throws {
            if firesImmediately { return }
            let id = UUID.v7()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if firesImmediately {
                        continuation.resume()
                    } else {
                        sleeps[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelSleep(id) }
            }
        }

        func fireAllSleeps() {
            firesImmediately = true
            let continuations = sleeps.values
            sleeps.removeAll()
            continuations.forEach { $0.resume() }
        }

        private func cancelSleep(_ id: UUID) {
            sleeps.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
    }
#endif
