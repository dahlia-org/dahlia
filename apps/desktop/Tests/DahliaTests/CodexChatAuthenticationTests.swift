import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Synchronization
    import Testing

    @MainActor
    struct CodexChatAuthenticationTests {
        private struct AuthenticationFailure: Error {}

        private struct WorkspaceLocator: CodexChatWorkspaceLocating {
            let url: URL

            func workspaceURL(vaultID: UUID) throws -> URL {
                url.appending(path: vaultID.uuidString.lowercased(), directoryHint: .isDirectory)
            }
        }

        @Test
        func sendWaitsForProviderAuthenticationPreparation() async throws {
            let transport = TestCodexChatAppServerTransport()
            let preparationStarted = AsyncStream.makeStream(of: Void.self)
            let releasePreparation = AsyncStream.makeStream(of: Void.self)
            let appServer = makeTestCodexAppServerService(
                transportFactory: { transport },
                providerAuthenticationPreparation: { _, _ in
                    preparationStarted.continuation.yield()
                    for await _ in releasePreparation.stream {
                        break
                    }
                    return false
                }
            )
            let service = CodexChatService(appServer: appServer)

            let send = Task {
                try await service.send(
                    threadID: "thread-1",
                    inputs: [.text("Hi")],
                    model: "default-model",
                    effort: "medium"
                )
            }
            for await _ in preparationStarted.stream {
                break
            }
            #expect(await transport.messages().isEmpty)

            releasePreparation.continuation.yield()
            let stream = try await send.value
            for try await _ in stream {}
            #expect(await transport.messages().contains {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            })
            await appServer.shutdown()
        }

        @Test
        func authenticationFailureDoesNotStartTurn() async {
            let transport = TestCodexChatAppServerTransport()
            let appServer = makeTestCodexAppServerService(
                transportFactory: { transport },
                providerAuthenticationPreparation: { _, _ in throw AuthenticationFailure() }
            )
            let service = CodexChatService(appServer: appServer)

            await #expect(throws: AuthenticationFailure.self) {
                _ = try await service.send(
                    threadID: "thread-1",
                    inputs: [.text("Hi")],
                    model: "default-model",
                    effort: "medium"
                )
            }
            #expect(await transport.messages().isEmpty)
            await appServer.shutdown()
        }

        @Test
        func turnDoesNotStartWhenPreparedProviderChangesDuringReadinessWait() async {
            let transport = TestCodexChatAppServerTransport()
            let provider = Mutex(CodexRuntimeProvider.chatGPTSubscription)
            let ready = Mutex(false)
            let readinessStarted = AsyncStream.makeStream(of: Void.self)
            let appServer = makeTestCodexAppServerService(
                transportFactory: { transport },
                configurationReadiness: {
                    readinessStarted.continuation.yield()
                    while !ready.withLock({ $0 }) { await Task.yield() }
                    return true
                },
                runtimeProviderResolver: { provider.withLock { $0 } }
            )
            let service = CodexChatService(appServer: appServer)
            let turn = Task {
                try await service.beginTurn(
                    threadID: "thread-1",
                    inputs: [.text("Do not send")],
                    model: "default-model",
                    effort: "medium",
                    approvalMethod: .autoReview,
                    expectedProvider: .chatGPTSubscription
                )
            }
            for await _ in readinessStarted.stream { break }
            provider.withLock { $0 = .databricks(profile: "WORK") }
            ready.withLock { $0 = true }

            await #expect(throws: CodexConfigurationError.self) { _ = try await turn.value }
            #expect(await transport.messages().isEmpty)
            await appServer.shutdown()
        }

        @Test
        func authenticationPreparesProviderSelectedAfterReadinessWait() async throws {
            let transport = TestCodexChatAppServerTransport()
            let provider = Mutex(CodexRuntimeProvider.chatGPTSubscription)
            let preparedProviders = Mutex<[CodexRuntimeProvider]>([])
            let ready = Mutex(false)
            let readinessStarted = AsyncStream.makeStream(of: Void.self)
            let appServer = makeTestCodexAppServerService(
                transportFactory: { transport },
                providerAuthenticationPreparation: { preparedProvider, _ in
                    preparedProviders.withLock { $0.append(preparedProvider) }
                    return false
                },
                configurationReadiness: {
                    readinessStarted.continuation.yield()
                    while !ready.withLock({ $0 }) { await Task.yield() }
                    return true
                },
                runtimeProviderResolver: { provider.withLock { $0 } }
            )
            let service = CodexChatService(appServer: appServer)
            let send = Task {
                try await service.send(
                    threadID: "thread-1",
                    inputs: [.text("Hi")],
                    model: "default-model",
                    effort: "medium"
                )
            }
            for await _ in readinessStarted.stream { break }
            provider.withLock { $0 = .databricks(profile: "WORK") }
            ready.withLock { $0 = true }

            let stream = try await send.value
            for try await _ in stream {}
            #expect(preparedProviders.withLock { $0 } == [.databricks(profile: "WORK")])
            #expect(await transport.messages().contains {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            })
            await appServer.shutdown()
        }

        @Test
        func chatHistoryOperationsShareAuthenticationBeforeSendingRequests() async throws {
            let first = TestCodexChatAppServerTransport()
            let second = TestCodexChatAppServerTransport()
            let transports = Mutex([first, second])
            let preparationCount = Mutex(0)
            let preparationStarted = AsyncStream.makeStream(of: Void.self)
            let releasePreparation = AsyncStream.makeStream(of: Void.self)
            let appServer = makeTestCodexAppServerService(
                transportFactory: { transports.withLock { $0.removeFirst() } },
                providerAuthenticationPreparation: { _, _ in
                    preparationCount.withLock { $0 += 1 }
                    preparationStarted.continuation.yield()
                    for await _ in releasePreparation.stream {
                        break
                    }
                    return true
                }
            )
            let service = CodexChatService(
                appServer: appServer,
                workspaceLocator: WorkspaceLocator(url: URL(filePath: "/tmp/dahlia-chat-auth")),
                mcpExecutableURL: URL(filePath: "/tmp/dahlia-mcp")
            )
            let vaultID = UUID.v7()
            try await appServer.start()

            let models = Task { try await service.models() }
            let list = Task { try await service.listThreads(vaultID: vaultID) }
            let load = Task { try await service.loadThread(id: "thread-history") }
            let resume = Task { try await service.resumeThread(id: "thread-history", vaultID: vaultID) }
            for await _ in preparationStarted.stream {
                break
            }
            #expect(await pollUntil(timeout: .seconds(10)) {
                await appServer.providerAuthenticationWaiterCountForTesting == 4
            })
            let firstMethods = await first.messages().compactMap { $0.objectValue?["method"]?.stringValue }
            #expect(!firstMethods.contains("model/list"))
            #expect(!firstMethods.contains("thread/list"))
            #expect(!firstMethods.contains("thread/read"))
            #expect(!firstMethods.contains("thread/resume"))

            releasePreparation.continuation.yield()
            _ = try await models.value
            _ = try await list.value
            _ = try await load.value
            _ = try await resume.value

            let secondMethods = await second.messages().compactMap { $0.objectValue?["method"]?.stringValue }
            #expect(secondMethods.contains("model/list"))
            #expect(secondMethods.contains("thread/list"))
            #expect(secondMethods.contains("thread/read"))
            #expect(secondMethods.contains("thread/resume"))
            #expect(preparationCount.withLock { $0 } == 1)
            await appServer.shutdown()
        }

        @Test
        func modelAndNewThreadWaitForReloadThatIsDrainingChat() async throws {
            let first = TestCodexChatAppServerTransport(turnOutcome: .disconnected)
            let second = TestCodexChatAppServerTransport()
            let transports = Mutex([first, second])
            let appServer = makeTestCodexAppServerService(
                transportFactory: { transports.withLock { $0.removeFirst() } }
            )
            let service = CodexChatService(
                appServer: appServer,
                workspaceLocator: WorkspaceLocator(url: URL(filePath: "/tmp/dahlia-chat-reload")),
                mcpExecutableURL: URL(filePath: "/tmp/dahlia-mcp")
            )
            let activeTurn = try await appServer.startChatTurn(
                threadID: "chat-thread",
                params: .object([
                    "input": .array([.object(["type": .string("text"), "text": .string("Hi")])]),
                    "threadId": .string("chat-thread"),
                ])
            )
            let consumption = Task {
                for try await _ in activeTurn.notifications {}
            }
            let reload = Task { try await appServer.reloadConfiguration() }
            await appServer.waitUntilChatTurnReloadIsWaitingForTesting()
            let newThread = Task {
                try await service.startThread(model: nil, effort: "medium", vaultID: UUID.v7())
            }
            await Task.yield()
            let firstMethods = await first.messages().compactMap { $0.objectValue?["method"]?.stringValue }
            #expect(!firstMethods.contains("model/list"))
            #expect(!firstMethods.contains("thread/start"))

            await first.sendFromServer(.object([
                "method": .string("turn/completed"),
                "params": .object([
                    "threadId": .string("chat-thread"),
                    "turn": .object([
                        "id": .string(activeTurn.turnID),
                        "status": .string("completed"),
                    ]),
                ]),
            ]))

            try await consumption.value
            try await reload.value
            _ = try await newThread.value
            let secondMethods = await second.messages().compactMap { $0.objectValue?["method"]?.stringValue }
            #expect(secondMethods.contains("model/list"))
            #expect(secondMethods.contains("thread/start"))
            await appServer.shutdown()
        }

        @Test
        func newThreadKeepsOneConnectionWhileReloadStartsDuringModelSelection() async throws {
            let first = TestCodexChatAppServerTransport(automaticallyRespondsToModelList: false)
            let second = TestCodexChatAppServerTransport()
            let transports = Mutex([first, second])
            let appServer = makeTestCodexAppServerService(
                transportFactory: { transports.withLock { $0.removeFirst() } }
            )
            let service = CodexChatService(
                appServer: appServer,
                workspaceLocator: WorkspaceLocator(url: URL(filePath: "/tmp/dahlia-chat-reload")),
                mcpExecutableURL: URL(filePath: "/tmp/dahlia-mcp")
            )

            let newThread = Task {
                try await service.startThread(model: nil, effort: "medium", vaultID: UUID.v7())
            }
            #expect(await pollUntil(timeout: .seconds(10)) {
                await first.messages().contains { $0.objectValue?["method"]?.stringValue == "model/list" }
            })
            let modelRequestID = try #require(await first.messages().first {
                $0.objectValue?["method"]?.stringValue == "model/list"
            }?.objectValue?["id"]?.intValue)

            let reload = Task { try await appServer.reloadConfiguration() }
            await first.sendFromServer(.object([
                "id": .number(Double(modelRequestID)),
                "result": TestCodexChatFixtures.modelList,
            ]))

            _ = try await newThread.value
            try await reload.value
            let firstMethods = await first.messages().compactMap { $0.objectValue?["method"]?.stringValue }
            #expect(firstMethods.contains("config/read"))
            #expect(firstMethods.contains("thread/start"))
            let secondMethods = await second.messages().compactMap { $0.objectValue?["method"]?.stringValue }
            #expect(!secondMethods.contains("model/list"))
            #expect(!secondMethods.contains("thread/start"))
            await appServer.shutdown()
        }
    }
#endif
