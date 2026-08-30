import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexAppServerApprovalRoutingTests {
        private typealias ChatTurn = (
            turnID: String,
            notifications: AsyncThrowingStream<JSONValue, any Error>
        )

        @Test
        func lateApprovalFromCancelledTurnIsNotAttachedToReplacementStart() async throws {
            let transport = TestCodexAppServerTransport(mode: .blockTurnStart)
            let service = makeTestCodexAppServerService(transportFactory: { transport })

            let replacementStart = await startReplacementAfterCancellingFirst(
                service: service,
                transport: transport
            )
            await sendLateApproval(to: transport)
            #expect(await pollUntil {
                await service.hasPendingApprovalForTesting("s:approval-late")
            })

            let replacementTurn = try await completeReplacementStart(
                replacementStart,
                transport: transport
            )
            try await expectLateApprovalCancelled(service: service, transport: transport)
            try await expectStaleTurnBufferDiscarded(service: service, transport: transport)
            try await completeReplacementTurn(replacementTurn, transport: transport)
            await service.shutdown()
        }

        private func startReplacementAfterCancellingFirst(
            service: CodexAppServerService,
            transport: TestCodexAppServerTransport
        ) async -> Task<ChatTurn, any Error> {
            let cancelledStart = Task {
                try await service.startChatTurn(threadID: "thread-1", params: chatTurnParams)
            }
            await transport.waitUntilSent("turn/start")
            cancelledStart.cancel()
            await #expect(throws: CancellationError.self) {
                try await cancelledStart.value
            }

            let replacementStart = Task {
                try await service.startChatTurn(threadID: "thread-1", params: chatTurnParams)
            }
            await transport.waitUntilSent("turn/start", count: 2)
            return replacementStart
        }

        private func sendLateApproval(to transport: TestCodexAppServerTransport) async {
            await transport.sendFromServer(.object([
                "id": .string("approval-late"),
                "method": .string("item/commandExecution/requestApproval"),
                "params": .object([
                    "command": .string("touch late"),
                    "itemId": .string("item-late"),
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                ]),
            ]))
        }

        private func completeReplacementStart(
            _ replacementStart: Task<ChatTurn, any Error>,
            transport: TestCodexAppServerTransport
        ) async throws -> ChatTurn {
            let requestID = try #require(await transport.messages().last {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            }?.objectValue?["id"]?.intValue)
            await transport.sendFromServer(.object([
                "id": .number(Double(requestID)),
                "result": .object([
                    "turn": .object([
                        "id": .string("turn-2"),
                        "status": .string("inProgress"),
                    ]),
                ]),
            ]))
            let turn = try await replacementStart.value
            #expect(turn.turnID == "turn-2")
            return turn
        }

        private func expectLateApprovalCancelled(
            service: CodexAppServerService,
            transport: TestCodexAppServerTransport
        ) async throws {
            #expect(await pollUntil(timeout: .seconds(10)) {
                await transport.messages().contains {
                    $0.objectValue?["id"] == .string("approval-late")
                        && $0.objectValue?["method"] == nil
                }
            })
            let approval = try #require(await transport.messages().first {
                $0.objectValue?["id"] == .string("approval-late")
                    && $0.objectValue?["method"] == nil
            }?.objectValue)
            #expect(approval["result"]?.objectValue?["decision"] == .string("cancel"))
            #expect(await !service.hasPendingApprovalForTesting("s:approval-late"))
        }

        private func expectStaleTurnBufferDiscarded(
            service: CodexAppServerService,
            transport: TestCodexAppServerTransport
        ) async throws {
            await transport.waitUntilSent("turn/interrupt")
            let interrupt = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "turn/interrupt"
            }?.objectValue?["params"]?.objectValue)
            #expect(interrupt["threadId"] == .string("thread-1"))
            #expect(interrupt["turnId"] == .string("turn-1"))

            let notifications = await service.notifications(threadID: "thread-1", turnID: "turn-1")
            let collection = collectMethods(from: notifications)
            await sendTurnCompleted(turnID: "turn-1", status: "interrupted", to: transport)
            #expect(try await collection.value == ["turn/completed"])
        }

        private func completeReplacementTurn(
            _ turn: ChatTurn,
            transport: TestCodexAppServerTransport
        ) async throws {
            let collection = collectMethods(from: turn.notifications)
            await sendTurnCompleted(turnID: turn.turnID, status: "completed", to: transport)
            #expect(try await collection.value == ["turn/completed"])
        }

        private func collectMethods(
            from notifications: AsyncThrowingStream<JSONValue, any Error>
        ) -> Task<[String], any Error> {
            Task {
                var methods: [String] = []
                for try await message in notifications {
                    if let method = message.objectValue?["method"]?.stringValue {
                        methods.append(method)
                    }
                }
                return methods
            }
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

        private var chatTurnParams: JSONValue {
            .object(["threadId": .string("thread-1")])
        }
    }
#endif
