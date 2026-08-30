import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexAppServerMCPApprovalRuntimeTests {
        @Test
        func MCPToolInputCanApproveAnOwnedMCPToolCall() async throws {
            let context = try await startTurn()
            let service = context.service
            let transport = context.transport
            let turn = context.turn
            let collection = context.collection
            await sendMCPToolApproval(id: "mcp-approval", turnID: "turn-1", to: transport)
            #expect(await pollUntil {
                await service.hasOwnedChatApprovalForTesting(
                    turnID: turn.id,
                    approvalID: "s:mcp-approval"
                )
            })

            try await service.decideChatApproval(
                turnID: turn.id,
                approvalID: "s:mcp-approval",
                decision: .accept
            )
            await transport.waitUntilResponded(to: "mcp-approval")
            let response = try #require(await response(id: "mcp-approval", from: transport))
            #expect(response["error"] == nil)
            #expect(response["result"]?.objectValue?["answers"] == answers("Allow"))

            try await finishTurn(collection: collection, transport: transport)
            await service.shutdown()
        }

        @Test
        func MCPToolInputCannotBeApprovedForSession() async throws {
            let context = try await startTurn()
            let service = context.service
            let transport = context.transport
            let turn = context.turn
            let collection = context.collection
            await sendMCPToolApproval(id: "mcp-session", turnID: "turn-1", to: transport)
            #expect(await pollUntil {
                await service.hasOwnedChatApprovalForTesting(
                    turnID: turn.id,
                    approvalID: "s:mcp-session"
                )
            })

            try await service.decideChatApproval(
                turnID: turn.id,
                approvalID: "s:mcp-session",
                decision: .acceptForSession
            )
            await transport.waitUntilResponded(to: "mcp-session")
            let received = try #require(await response(id: "mcp-session", from: transport))
            #expect(received["result"]?.objectValue?["answers"] == answers("Cancel"))

            try await finishTurn(collection: collection, transport: transport)
            await service.shutdown()
        }

        @Test
        func genericUserInputReturnsTheSelectedAnswer() async throws {
            let context = try await startTurn()
            let service = context.service
            let transport = context.transport
            await sendUserInput(id: "user-input", turnID: "turn-1", to: transport)
            #expect(await pollUntil {
                await service.hasOwnedChatApprovalForTesting(
                    turnID: context.turn.id,
                    approvalID: "s:user-input"
                )
            })

            try await service.respondToChatUserInput(
                turnID: context.turn.id,
                requestID: "s:user-input",
                answer: "Next steps"
            )
            await transport.waitUntilResponded(to: "user-input")
            let received = try #require(await response(id: "user-input", from: transport))
            #expect(received["result"]?.objectValue?["answers"] == answers(
                questionID: "desired_outcome",
                answer: "Next steps"
            ))

            try await finishTurn(collection: context.collection, transport: transport)
            await service.shutdown()
        }

        @Test
        func genericUserInputWriteFailureStopsConnection() async throws {
            let context = try await startTurn(failsApprovalResponses: true)
            await sendUserInput(id: "user-input", turnID: "turn-1", to: context.transport)
            #expect(await pollUntil {
                await context.service.hasOwnedChatApprovalForTesting(
                    turnID: context.turn.id,
                    approvalID: "s:user-input"
                )
            })

            await #expect(throws: CancellationError.self) {
                try await context.service.respondToChatUserInput(
                    turnID: context.turn.id,
                    requestID: "s:user-input",
                    answer: "Next steps"
                )
            }
            #expect(await context.transport.isClosed)
            _ = try? await context.collection.value
            await context.service.shutdown()
        }

        @Test
        func permissionRequestRemainsFailClosed() async throws {
            let context = try await startTurn()
            let service = context.service
            let transport = context.transport
            let turn = context.turn
            let collection = context.collection
            await transport.sendFromServer(.object([
                "id": .string("permission-escalation"),
                "method": .string("item/permissions/requestApproval"),
                "params": .object([
                    "cwd": .string("/tmp"),
                    "itemId": .string("item-1"),
                    "permissions": .object([
                        "network": .object(["enabled": .bool(true)]),
                    ]),
                    "startedAtMs": .number(1_700_000_000_000),
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                ]),
            ]))
            await transport.waitUntilResponded(to: "permission-escalation")
            let received = try #require(await response(id: "permission-escalation", from: transport))
            #expect(received["result"] == nil)
            #expect(received["error"]?.objectValue?["code"] == .number(-32000))
            #expect(await !service.hasOwnedChatApprovalForTesting(
                turnID: turn.id,
                approvalID: "s:permission-escalation"
            ))

            try await finishTurn(collection: collection, transport: transport)
            await service.shutdown()
        }

        @Test
        func stopCancelsMCPToolInputBeforeInterrupt() async throws {
            let context = try await startTurn()
            let service = context.service
            let transport = context.transport
            let turn = context.turn
            let collection = context.collection
            await sendMCPToolApproval(id: "mcp-approval", turnID: "turn-1", to: transport)
            #expect(await pollUntil {
                await service.hasOwnedChatApprovalForTesting(
                    turnID: turn.id,
                    approvalID: "s:mcp-approval"
                )
            })

            let stop = Task { await service.stopChatTurn(turn.id) }
            await transport.waitUntilResponded(to: "mcp-approval")
            await transport.waitUntilSent("turn/interrupt")
            let messages = await transport.messages()
            let approvalIndex = try #require(messages.firstIndex {
                $0.objectValue?["id"] == .string("mcp-approval")
                    && $0.objectValue?["method"] == nil
            })
            let interruptIndex = try #require(messages.firstIndex {
                $0.objectValue?["method"]?.stringValue == "turn/interrupt"
            })
            #expect(approvalIndex < interruptIndex)
            #expect(messages[approvalIndex].objectValue?["result"]?.objectValue?["answers"] == answers("Cancel"))

            await sendTurnCompleted(turnID: "turn-1", status: "interrupted", to: transport)
            await stop.value
            try await collection.value
            let responses = await transport.messages().filter {
                $0.objectValue?["id"] == .string("mcp-approval")
                    && $0.objectValue?["method"] == nil
            }
            #expect(responses.count == 1)
            await service.shutdown()
        }

        private struct TurnContext {
            let service: CodexAppServerService
            let transport: TestCodexAppServerTransport
            let turn: CodexAppServerChatTurn
            let collection: Task<Void, any Error>
        }

        private func startTurn(failsApprovalResponses: Bool = false) async throws -> TurnContext {
            let transport = TestCodexAppServerTransport(
                mode: .blockTurnStart,
                failsApprovalResponses: failsApprovalResponses
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
            return TurnContext(
                service: service,
                transport: transport,
                turn: turn,
                collection: collection
            )
        }

        private func finishTurn(
            collection: Task<Void, any Error>,
            transport: TestCodexAppServerTransport
        ) async throws {
            await sendTurnCompleted(turnID: "turn-1", status: "completed", to: transport)
            try await collection.value
        }

        private func response(
            id: String,
            from transport: TestCodexAppServerTransport
        ) async -> [String: JSONValue]? {
            await transport.messages().first {
                $0.objectValue?["id"] == .string(id) && $0.objectValue?["method"] == nil
            }?.objectValue
        }

        private func answers(_ answer: String) -> JSONValue {
            answers(questionID: "mcp_tool_call_approval_item-1", answer: answer)
        }

        private func answers(questionID: String, answer: String) -> JSONValue {
            .object([
                questionID: .object([
                    "answers": .array([.string(answer)]),
                ]),
            ])
        }

        private func sendUserInput(
            id: String,
            turnID: String,
            to transport: TestCodexAppServerTransport
        ) async {
            await transport.sendFromServer(.object([
                "id": .string(id),
                "method": .string("item/tool/requestUserInput"),
                "params": .object([
                    "autoResolutionMs": .null,
                    "isBlocking": .bool(false),
                    "itemId": .string("item-1"),
                    "questions": .array([.object([
                        "header": .string("Outcome"),
                        "id": .string("desired_outcome"),
                        "isOther": .bool(true),
                        "isSecret": .bool(false),
                        "options": .array([.object([
                            "description": .string("Agree on next steps."),
                            "label": .string("Next steps"),
                        ])]),
                        "question": .string("What outcome did you want?"),
                    ])]),
                    "threadId": .string("thread-1"),
                    "turnId": .string(turnID),
                ]),
            ]))
        }

        private func sendMCPToolApproval(
            id: String,
            turnID: String,
            to transport: TestCodexAppServerTransport
        ) async {
            await transport.sendFromServer(.object([
                "id": .string(id),
                "method": .string("item/tool/requestUserInput"),
                "params": .object([
                    "itemId": .string("item-1"),
                    "questions": .array([
                        .object([
                            "header": .string("Approve app tool call?"),
                            "id": .string("mcp_tool_call_approval_item-1"),
                            "isOther": .bool(false),
                            "isSecret": .bool(false),
                            "options": .array([
                                .object([
                                    "description": .string("Run the tool and continue."),
                                    "label": .string("Allow"),
                                ]),
                                .object([
                                    "description": .string("Cancel this tool call."),
                                    "label": .string("Cancel"),
                                ]),
                            ]),
                            "question": .string("Allow the dahlia MCP server to run tool?"),
                        ]),
                    ]),
                    "threadId": .string("thread-1"),
                    "turnId": .string(turnID),
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
