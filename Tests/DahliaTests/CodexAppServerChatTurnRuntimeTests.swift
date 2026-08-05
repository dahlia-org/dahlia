import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexAppServerChatTurnRuntimeTests {
        @Test
        func failedTurnStartWriteResetsConnectionAfterRequestMayHaveBeenDelivered() async {
            let transport = TestCodexAppServerTransport(
                mode: .blockTurnStart,
                failsTurnStartWrites: true
            )
            let service = makeTestCodexAppServerService(transportFactory: { transport })

            await #expect(throws: CancellationError.self) {
                try await service.beginChatTurn(
                    threadID: "thread-1",
                    params: .object(["threadId": .string("thread-1")])
                )
            }

            #expect(await transport.isClosed)
            await service.shutdown()
        }

        @Test
        func beginReturnsLocalHandleBeforeServerStartResponseAndOwnsEarlyApproval() async throws {
            let transport = TestCodexAppServerTransport(mode: .blockTurnStart)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let turn = try await service.beginChatTurn(
                threadID: "thread-1",
                params: .object(["threadId": .string("thread-1")])
            )
            await transport.waitUntilSent("turn/start")

            let startRequest = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            }?.objectValue)
            #expect(startRequest["params"]?.objectValue?["clientUserMessageId"] == .string(turn.id.uuidString))

            let collection = Task {
                var startedTurnID: String?
                var requestedApprovalID: String?
                var resolvedApprovalID: String?
                for try await event in turn.events {
                    switch event {
                    case let .started(turnID):
                        startedTurnID = turnID
                    case let .message(message):
                        guard message.objectValue?["method"]?.stringValue
                            == "item/commandExecution/requestApproval" else { continue }
                        requestedApprovalID = message.objectValue?["id"].flatMap {
                            CodexAppServerService.approvalID(for: $0)
                        }
                    case let .approvalResolved(id):
                        resolvedApprovalID = id
                    }
                }
                return (startedTurnID, requestedApprovalID, resolvedApprovalID)
            }

            await sendApproval(id: "approval-1", turnID: "turn-1", to: transport)
            #expect(await pollUntil {
                await service.hasOwnedChatApprovalForTesting(turnID: turn.id, approvalID: "s:approval-1")
            })
            try await service.decideChatApproval(
                turnID: turn.id,
                approvalID: "s:approval-1",
                decision: .accept
            )
            await sendApprovalResolved(id: "approval-1", threadID: "thread-2", to: transport)
            #expect(await pollUntil {
                await service.hasRespondedChatApprovalForTesting(
                    turnID: turn.id,
                    approvalID: "s:approval-1"
                )
            })
            await sendApprovalResolved(id: "approval-1", threadID: "thread-1", to: transport)
            #expect(await pollUntil {
                await !service.hasRespondedChatApprovalForTesting(
                    turnID: turn.id,
                    approvalID: "s:approval-1"
                )
            })
            await sendTurnCompleted(turnID: "turn-1", status: "completed", to: transport)

            let result = try await collection.value
            #expect(result.0 == "turn-1")
            #expect(result.1 == "s:approval-1")
            #expect(result.2 == "s:approval-1")
            await service.shutdown()
        }

        @Test
        func stopCancelsApprovalBeforeInterruptAndWaitsForTerminalEvent() async throws {
            let transport = TestCodexAppServerTransport(mode: .blockTurnStart)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let turn = try await service.beginChatTurn(
                threadID: "thread-1",
                params: .object(["threadId": .string("thread-1")])
            )
            let collection = Task {
                for try await _ in turn.events {}
            }
            await transport.sendFromServer(.object([
                "method": .string("turn/started"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turn": .object(["id": .string("turn-1")]),
                ]),
            ]))
            await sendApproval(id: "approval-1", turnID: "turn-1", to: transport)
            #expect(await pollUntil {
                await service.hasOwnedChatApprovalForTesting(turnID: turn.id, approvalID: "s:approval-1")
            })

            let stop = Task { await service.stopChatTurn(turn.id) }
            await transport.waitUntilResponded(to: "approval-1")
            await transport.waitUntilSent("turn/interrupt")
            let messages = await transport.messages()
            let approvalIndex = try #require(messages.firstIndex {
                $0.objectValue?["id"] == .string("approval-1")
                    && $0.objectValue?["method"] == nil
            })
            let interruptIndex = try #require(messages.firstIndex {
                $0.objectValue?["method"]?.stringValue == "turn/interrupt"
            })
            #expect(approvalIndex < interruptIndex)
            #expect(messages[approvalIndex].objectValue?["result"]?.objectValue?["decision"] == .string("cancel"))

            await sendTurnCompleted(turnID: "turn-1", status: "interrupted", to: transport)
            await stop.value
            try await collection.value
            await service.shutdown()
        }

        @Test
        func terminalEventDuringApprovalCancellationDoesNotResetConnection() async throws {
            let transport = TestCodexAppServerTransport(
                mode: .blockTurnStart,
                blocksApprovalResponses: true
            )
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let turn = try await service.beginChatTurn(
                threadID: "thread-1",
                params: .object(["threadId": .string("thread-1")])
            )
            let collection = Task {
                for try await _ in turn.events {}
            }
            await transport.sendFromServer(.object([
                "method": .string("turn/started"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turn": .object(["id": .string("turn-1")]),
                ]),
            ]))
            await sendApproval(id: "approval-1", turnID: "turn-1", to: transport)
            #expect(await pollUntil {
                await service.hasOwnedChatApprovalForTesting(turnID: turn.id, approvalID: "s:approval-1")
            })

            let stop = Task { await service.stopChatTurn(turn.id) }
            await transport.waitUntilResponded(to: "approval-1")
            await sendTurnCompleted(turnID: "turn-1", status: "interrupted", to: transport)
            await transport.releaseBlockedApprovalResponse()

            await stop.value
            try await collection.value
            #expect(await !transport.isClosed)
            let responses = await transport.messages().filter {
                $0.objectValue?["id"] == .string("approval-1")
                    && $0.objectValue?["method"] == nil
            }
            #expect(responses.count == 1)
            #expect(responses.first?.objectValue?["result"]?.objectValue?["decision"] == .string("cancel"))
            await service.shutdown()
        }

        @Test
        func stoppingBeforeWireTurnIdentityResetsTheConnection() async throws {
            let transport = TestCodexAppServerTransport(mode: .blockTurnStart)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let turn = try await service.beginChatTurn(
                threadID: "thread-1",
                params: .object(["threadId": .string("thread-1")])
            )
            let collection = Task {
                for try await _ in turn.events {}
            }

            await service.stopChatTurn(turn.id)

            #expect(await transport.isClosed)
            await #expect(throws: CodexAppServerError.self) {
                try await collection.value
            }
            await service.shutdown()
        }

        @Test
        func lateApprovalFromRetiredTurnIsNotAttachedToReplacementHandle() async throws {
            let transport = TestCodexAppServerTransport(mode: .blockTurnStart)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            let first = try await service.beginChatTurn(
                threadID: "thread-1",
                params: .object(["threadId": .string("thread-1")])
            )
            let firstCollection = Task {
                for try await _ in first.events {}
            }
            await transport.sendFromServer(.object([
                "method": .string("turn/started"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turn": .object(["id": .string("turn-1")]),
                ]),
            ]))
            await sendTurnCompleted(turnID: "turn-1", status: "completed", to: transport)
            try await firstCollection.value

            let replacement = try await service.beginChatTurn(
                threadID: "thread-1",
                params: .object(["threadId": .string("thread-1")])
            )
            let replacementCollection = Task {
                for try await _ in replacement.events {}
            }
            await sendApproval(id: "approval-late", turnID: "turn-1", to: transport)
            await transport.waitUntilResponded(to: "approval-late")

            #expect(await !service.hasOwnedChatApprovalForTesting(
                turnID: replacement.id,
                approvalID: "s:approval-late"
            ))
            let response = try #require(await transport.messages().first {
                $0.objectValue?["id"] == .string("approval-late")
                    && $0.objectValue?["method"] == nil
            })
            #expect(response.objectValue?["result"]?.objectValue?["decision"] == .string("decline"))

            await transport.sendFromServer(.object([
                "method": .string("turn/started"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turn": .object(["id": .string("turn-2")]),
                ]),
            ]))
            await sendTurnCompleted(turnID: "turn-2", status: "completed", to: transport)
            try await replacementCollection.value
            await service.shutdown()
        }

        @Test
        func chatThreadLeaseOnlyUnsubscribesAfterFinalOwnerReleases() async throws {
            let transport = TestCodexAppServerTransport(mode: .models)
            let service = makeTestCodexAppServerService(transportFactory: { transport })
            try await service.start()
            let first = await service.acquireChatThreadLease("thread-1")
            let second = await service.acquireChatThreadLease("thread-1")

            #expect(await !service.releaseChatThreadLease("thread-1", leaseID: first))
            #expect(await transport.messages().allSatisfy {
                $0.objectValue?["method"]?.stringValue != "thread/unsubscribe"
            })
            #expect(await service.releaseChatThreadLease("thread-1", leaseID: second))
            await transport.waitUntilSent("thread/unsubscribe")
            await service.shutdown()
        }

        private func sendApproval(
            id: String,
            turnID: String,
            to transport: TestCodexAppServerTransport
        ) async {
            await transport.sendFromServer(.object([
                "id": .string(id),
                "method": .string("item/commandExecution/requestApproval"),
                "params": .object([
                    "command": .string("date"),
                    "itemId": .string("item-1"),
                    "threadId": .string("thread-1"),
                    "turnId": .string(turnID),
                ]),
            ]))
        }

        private func sendApprovalResolved(
            id: String,
            threadID: String,
            to transport: TestCodexAppServerTransport
        ) async {
            await transport.sendFromServer(.object([
                "method": .string("serverRequest/resolved"),
                "params": .object([
                    "requestId": .string(id),
                    "threadId": .string(threadID),
                ]),
            ]))
        }

        private func sendTurnCompleted(
            turnID: String,
            status: String,
            to transport: TestCodexAppServerTransport
        ) async {
            await transport.sendFromServer(.object([
                "method": .string("turn/completed"),
                "params": .object([
                    "threadId": .string("thread-1"),
                    "turn": .object([
                        "id": .string(turnID),
                        "status": .string(status),
                    ]),
                ]),
            ]))
        }
    }
#endif
