import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Synchronization
    import Testing

    @MainActor
    struct CodexChatServiceTests {
        @Test
        func persistentChatOmitsOutputSchemaAndReplaysEarlyDeltas() async throws {
            let transport = TestCodexChatAppServerTransport()
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })
            let workspace = URL(filePath: "/tmp/dahlia-chat-tests", directoryHint: .isDirectory)
            let service = CodexChatService(
                appServer: appServer,
                workspaceLocator: TestCodexChatWorkspaceLocator(url: workspace),
                mcpExecutableURL: URL(filePath: "/tmp/dahlia-mcp")
            )
            let vaultID = UUID.v7()

            let thread = try await service.startThread(model: "default-model", effort: "medium", vaultID: vaultID)
            let stream = try await service.send(
                threadID: thread.id,
                inputs: [.text("Meeting context"), .text("Hi")],
                model: "default-model",
                effort: "high"
            )
            var events: [CodexChatTurnEvent] = []
            for try await event in stream {
                events.append(event)
            }

            #expect(thread.id == "thread-1")
            #expect(events == [
                .started(turnID: "turn-1"),
                .reasoningDelta(itemID: "reasoning-1", summaryIndex: 0, text: "Checked the request"),
                .delta(itemID: "item-1", text: "Hel"),
                .delta(itemID: "item-1", text: "lo"),
                .reasoningCompleted(itemID: "reasoning-1", text: "Checked the request"),
                .completed(itemID: "item-1", text: "Hello"),
                .completed(itemID: nil, text: nil),
            ])

            let messages = await transport.messages()
            let threadParams = try #require(messages.first {
                $0.objectValue?["method"]?.stringValue == "thread/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(threadParams["ephemeral"] == .bool(false))
            #expect(threadParams["approvalPolicy"] == .string("on-request"))
            #expect(threadParams["sandbox"] == .string("workspace-write"))
            #expect(threadParams["cwd"] == .string(workspace.appending(path: vaultID.uuidString.lowercased()).path))
            let config = try #require(threadParams["config"]?.objectValue)
            expectChatConfiguration(config, vaultID: vaultID)
            expectDeveloperInstructions(threadParams["developerInstructions"]?.stringValue)

            let turnParams = try #require(messages.first {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(turnParams["outputSchema"] == nil)
            #expect(turnParams["approvalsReviewer"] == .string("user"))
            #expect(turnParams["effort"] == .string("high"))
            #expect(turnParams["summary"] == .string("auto"))
            #expect(turnParams["input"] == .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Meeting context"),
                ]),
                .object([
                    "type": .string("text"),
                    "text": .string("Hi"),
                ]),
            ]))
            await appServer.shutdown()
        }

        @Test(arguments: [AIAccountProvider.chatGPTSubscription, .databricks, nil])
        func approvalReviewerFollowsProvider(provider: AIAccountProvider?) async throws {
            let transport = TestCodexChatAppServerTransport()
            let appServer = makeTestCodexAppServerService(
                transportFactory: { transport },
                accountProviderResolver: { provider }
            )
            let service = CodexChatService(appServer: appServer)

            let stream = try await service.send(
                threadID: "thread-1",
                inputs: [.text("Hi")],
                model: "default-model",
                effort: "medium"
            )
            for try await _ in stream {}

            let turnParams = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            }?.objectValue?["params"]?.objectValue)
            let expectedReviewer = provider == .chatGPTSubscription ? "auto_review" : "user"
            #expect(turnParams["approvalsReviewer"] == .string(expectedReviewer))
            await appServer.shutdown()
        }

        @Test(arguments: CodexChatApprovalMethod.allCases)
        func approvalMethodControlsTurnAndStoredThreadSettings(method: CodexChatApprovalMethod) async throws {
            let transport = TestCodexChatAppServerTransport()
            let appServer = makeTestCodexAppServerService(
                transportFactory: { transport },
                accountProviderResolver: { .chatGPTSubscription }
            )
            let service = CodexChatService(appServer: appServer)

            let turn = try await service.beginTurn(
                threadID: "thread-1",
                inputs: [.text("Hi")],
                model: "default-model",
                effort: "medium",
                approvalMethod: method
            )
            for try await _ in turn.events {}
            let storedMethod = try await service.updateApprovalMethod(
                threadID: "thread-1",
                approvalMethod: method
            )

            let messages = await transport.messages()
            let turnParams = try #require(messages.first {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            }?.objectValue?["params"]?.objectValue)
            let settingsParams = try #require(messages.first {
                $0.objectValue?["method"]?.stringValue == "thread/settings/update"
            }?.objectValue?["params"]?.objectValue)
            let expectedPolicy = JSONValue.string(method == .fullAccess ? "never" : "on-request")
            let expectedReviewer = JSONValue.string(method == .autoReview ? "auto_review" : "user")
            let expectedSandbox: JSONValue = method == .fullAccess
                ? .object(["type": .string("dangerFullAccess")])
                : .object(["networkAccess": .bool(false), "type": .string("workspaceWrite")])
            for params in [turnParams, settingsParams] {
                #expect(params["approvalPolicy"] == expectedPolicy)
                #expect(params["approvalsReviewer"] == expectedReviewer)
                #expect(params["sandboxPolicy"] == expectedSandbox)
            }
            #expect(turn.approvalMethod == method)
            #expect(storedMethod == method)
            await appServer.shutdown()
        }

        @Test
        func autoReviewFallsBackToUserApprovalOutsideChatGPTSubscription() async throws {
            let transport = TestCodexChatAppServerTransport()
            let appServer = makeTestCodexAppServerService(
                transportFactory: { transport },
                accountProviderResolver: { .databricks }
            )
            let service = CodexChatService(appServer: appServer)

            let turn = try await service.beginTurn(
                threadID: "thread-1",
                inputs: [.text("Hi")],
                model: nil,
                effort: "medium",
                approvalMethod: .autoReview
            )
            for try await _ in turn.events {}
            let storedMethod = try await service.updateApprovalMethod(
                threadID: "thread-1",
                approvalMethod: .autoReview
            )

            let params = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(params["approvalPolicy"] == .string("on-request"))
            #expect(params["approvalsReviewer"] == .string("user"))
            #expect(params["sandboxPolicy"] == .object([
                "networkAccess": .bool(false),
                "type": .string("workspaceWrite"),
            ]))
            #expect(turn.approvalMethod == .ask)
            #expect(storedMethod == .ask)
            await appServer.shutdown()
        }

        @Test
        func legacyReadOnlyThreadDoesNotRestoreAsFullAccess() async throws {
            let transport = TestCodexChatAppServerTransport(
                resumedApprovalPolicy: .string("never"),
                resumedApprovalsReviewer: .string("user"),
                resumedSandbox: .object(["type": .string("readOnly")])
            )
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })
            let service = CodexChatService(
                appServer: appServer,
                mcpExecutableURL: URL(filePath: "/tmp/dahlia-mcp")
            )

            let thread = try await service.resumeThread(id: "thread-history", vaultID: UUID.v7())

            #expect(thread.approvalMethod == nil)
            await appServer.shutdown()
        }

        @Test
        func providerResolutionAndTurnStartDoNotCrossConfigurationReload() async throws {
            let first = TestCodexChatAppServerTransport()
            let second = TestCodexChatAppServerTransport()
            let transports = Mutex([first, second])
            let resolverStarted = AsyncStream.makeStream(of: Void.self)
            let releaseResolver = AsyncStream.makeStream(of: Void.self)
            let appServer = makeTestCodexAppServerService(
                transportFactory: { transports.withLock { $0.removeFirst() } },
                accountProviderResolver: {
                    resolverStarted.continuation.yield()
                    for await _ in releaseResolver.stream {
                        break
                    }
                    return .chatGPTSubscription
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
            for await _ in resolverStarted.stream {
                break
            }
            let reload = Task { try await appServer.reloadConfiguration() }
            #expect(await pollUntil(timeout: .seconds(10)) {
                if await appServer.codexOperationDrainWaiterCountForTesting == 1 {
                    return true
                }
                return await !(second.messages()).isEmpty
            })
            #expect(await appServer.codexOperationDrainWaiterCountForTesting == 1)
            #expect(await second.messages().isEmpty)

            releaseResolver.continuation.yield()
            let stream = try await send.value
            for try await _ in stream {}
            try await reload.value

            let turnParams = try #require(await first.messages().first {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(turnParams["approvalsReviewer"] == .string("auto_review"))
            await appServer.shutdown()
        }

        @Test
        func threadNameUsesPlainUserText() async throws {
            let transport = TestCodexChatAppServerTransport()
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })
            let service = CodexChatService(
                appServer: appServer,
                workspaceLocator: TestCodexChatWorkspaceLocator(url: URL(filePath: "/tmp/dahlia-chat-tests"))
            )

            await service.setThreadName(threadID: "thread-1", name: "Hi")

            let params = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "thread/name/set"
            }?.objectValue?["params"]?.objectValue)
            #expect(params["threadId"] == .string("thread-1"))
            #expect(params["name"] == .string("Hi"))
            await appServer.shutdown()
        }

        @Test
        func steeringAddsTextBlocksToTheExpectedActiveTurn() async throws {
            let transport = TestCodexChatAppServerTransport()
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })
            let service = CodexChatService(
                appServer: appServer,
                workspaceLocator: TestCodexChatWorkspaceLocator(url: URL(filePath: "/tmp/dahlia-chat-tests"))
            )

            let dataURI = TestCodexChatFixtures.historyImageDataURI
            try await service.steer(
                threadID: "thread-1",
                turnID: "turn-1",
                inputs: [.text("Live context"), .imageDataURI(dataURI)]
            )

            let params = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "turn/steer"
            }?.objectValue?["params"]?.objectValue)
            #expect(params["threadId"] == .string("thread-1"))
            #expect(params["expectedTurnId"] == .string("turn-1"))
            #expect(params["input"] == .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Live context"),
                ]),
                .object([
                    "type": .string("image"),
                    "url": .string(dataURI),
                ]),
            ]))
            await appServer.shutdown()
        }

        @Test
        func imageInputsAreSentAndRestoredFromHistory() async throws {
            let transport = TestCodexChatAppServerTransport()
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })
            let service = CodexChatService(
                appServer: appServer,
                workspaceLocator: TestCodexChatWorkspaceLocator(url: URL(filePath: "/tmp/dahlia-chat-images"))
            )
            let dataURI = TestCodexChatFixtures.historyImageDataURI

            _ = try await service.send(
                threadID: "thread-1",
                inputs: [.text("Describe this"), .imageDataURI(dataURI)],
                model: "default-model",
                effort: "medium"
            )
            let params = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(params["input"] == .array([
                .object(["type": .string("text"), "text": .string("Describe this")]),
                .object(["type": .string("image"), "url": .string(dataURI)]),
            ]))

            let loaded = try await service.loadThread(id: "thread-history")
            #expect(loaded.messages[0].images.count == 1)
            #expect(loaded.messages[0].images[0].dataURI == dataURI)
            #expect(loaded.messages[1].text.isEmpty)
            #expect(loaded.messages[1].images.count == 1)
            await appServer.shutdown()
        }

        @Test
        func turnInterruptionAndFailureAreTypedEvents() async throws {
            let interrupted = try await events(for: .interrupted)
            let failed = try await events(for: .failed)

            #expect(interrupted == [
                .started(turnID: "turn-1"),
                .interrupted,
            ])
            #expect(failed == [
                .started(turnID: "turn-1"),
                .failed(message: "Model unavailable"),
            ])
        }

        @Test
        func connectionLossFailsTheTurnStream() async throws {
            let transport = TestCodexChatAppServerTransport(turnOutcome: .disconnected)
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })
            let service = CodexChatService(
                appServer: appServer,
                workspaceLocator: TestCodexChatWorkspaceLocator(
                    url: URL(filePath: "/tmp/dahlia-chat-disconnect", directoryHint: .isDirectory)
                )
            )
            let stream = try await service.send(
                threadID: "thread-1",
                inputs: [.text("Disconnect")],
                model: "default-model",
                effort: "medium"
            )
            await transport.simulateDisconnect()

            do {
                for try await _ in stream {}
                Issue.record("Expected the disconnected stream to fail")
            } catch let error as CodexAppServerError {
                #expect(error == .processExited(nil))
            }
            await appServer.shutdown()
        }

        @Test
        func malformedTurnEventInterruptsTheOwnedRuntimeBeforeFailing() async throws {
            let transport = TestCodexChatAppServerTransport(turnOutcome: .disconnected)
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })
            let service = CodexChatService(
                appServer: appServer,
                workspaceLocator: TestCodexChatWorkspaceLocator(
                    url: URL(filePath: "/tmp/dahlia-chat-malformed", directoryHint: .isDirectory)
                )
            )
            let stream = try await service.send(
                threadID: "thread-1",
                inputs: [.text("Test")],
                model: "default-model",
                effort: "medium"
            )
            let collection = Task {
                for try await _ in stream {}
            }

            await transport.sendFromServer(.object([
                "method": .string("item/agentMessage/delta"),
                "params": .object([
                    "itemId": .string("item-1"),
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                ]),
            ]))
            #expect(await pollUntil {
                await transport.messages().contains {
                    $0.objectValue?["method"]?.stringValue == "turn/interrupt"
                }
            })
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

            await #expect(throws: CodexAppServerError.invalidProtocolResponse) {
                try await collection.value
            }
            #expect(await !transport.isClosed)
            await appServer.shutdown()
        }

        @Test
        func historyUsesExactWorkspaceAndBundledCodexSourceAndRestoresMessages() async throws {
            let transport = TestCodexChatAppServerTransport()
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })
            let workspace = URL(filePath: "/tmp/dahlia-chat-history", directoryHint: .isDirectory)
            let service = CodexChatService(
                appServer: appServer,
                workspaceLocator: TestCodexChatWorkspaceLocator(url: workspace),
                mcpExecutableURL: URL(filePath: "/tmp/dahlia-mcp")
            )
            let vaultID = UUID.v7()

            let page = try await service.listThreads(vaultID: vaultID)
            let loaded = try await service.loadThread(id: "thread-history")
            let resumed = try await service.resumeThread(id: "thread-history", vaultID: vaultID)

            #expect(page.threads.map(\.id) == ["thread-history"])
            #expect(page.nextCursor == "next-page")
            #expect(loaded.messages.map(\.text) == ["Question", "", "Answer", ""])
            #expect(loaded.messages[2].reasoning == "Reviewed the question\n\nPrepared the answer")
            #expect(loaded.messages[3].reasoning == "Reasoning without an answer")
            #expect(resumed.model == "default-model")
            #expect(resumed.reasoningEffort == "high")
            #expect(resumed.approvalMethod == .autoReview)
            guard case let .meeting(meetingID, meetingName, calendarEvent) = loaded.messages[0].context else {
                Issue.record("Expected restored Meeting context")
                return
            }
            #expect(meetingID.uuidString == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
            #expect(meetingName == "History meeting")
            #expect(calendarEvent == nil)

            let listParams = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "thread/list"
            }?.objectValue?["params"]?.objectValue)
            #expect(listParams["cwd"] == .array([
                .string(workspace.appending(path: vaultID.uuidString.lowercased()).path),
            ]))
            #expect(listParams["sourceKinds"] == .array([.string("vscode")]))
            #expect(listParams["sortKey"] == .string("recency_at"))
            #expect(listParams["sortDirection"] == .string("desc"))
            let resumeParams = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "thread/resume"
            }?.objectValue?["params"]?.objectValue)
            #expect(resumeParams["approvalPolicy"] == nil)
            #expect(resumeParams["sandbox"] == nil)
            expectDeveloperInstructions(resumeParams["developerInstructions"]?.stringValue)
            await appServer.shutdown()
        }

        @Test
        func approvalRequestsBecomeTurnEvents() async throws {
            let transport = TestCodexChatAppServerTransport(turnOutcome: .disconnected)
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })
            let service = CodexChatService(
                appServer: appServer,
                workspaceLocator: TestCodexChatWorkspaceLocator(
                    url: URL(filePath: "/tmp/dahlia-chat-approval", directoryHint: .isDirectory)
                )
            )
            let stream = try await service.send(
                threadID: "thread-1",
                inputs: [.text("Test")],
                model: "default-model",
                effort: "medium"
            )
            let collected = Task {
                var events: [CodexChatTurnEvent] = []
                for try await event in stream {
                    events.append(event)
                }
                return events
            }

            await transport.sendFromServer(.object([
                "id": .string("approval-1"),
                "method": .string("item/commandExecution/requestApproval"),
                "params": .object([
                    "command": .string("ls -la"),
                    "cwd": .string("/tmp/dahlia-chat-approval"),
                    "itemId": .string("item-1"),
                    "reason": .string("Needs the workspace listing"),
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                ]),
            ]))
            await transport.sendFromServer(.object([
                "method": .string("item/started"),
                "params": .object([
                    "item": .object([
                        "changes": .array([
                            .object([
                                "diff": .string("@@ -1 +1 @@\n-old\n+new"),
                                "kind": .object([
                                    "type": .string("update"),
                                    "move_path": .string("Sources/Renamed.swift"),
                                ]),
                                "path": .string("Sources/Example.swift"),
                            ]),
                        ]),
                        "id": .string("item-2"),
                        "status": .string("inProgress"),
                        "type": .string("fileChange"),
                    ]),
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                ]),
            ]))
            await transport.sendFromServer(.object([
                "id": .string("approval-2"),
                "method": .string("item/fileChange/requestApproval"),
                "params": .object([
                    "grantRoot": .string("/tmp/outside-workspace"),
                    "itemId": .string("item-2"),
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                ]),
            ]))
            await transport.sendFromServer(.object([
                "method": .string("item/started"),
                "params": .object([
                    "item": .object([
                        "arguments": .object([
                            "expected_project_id": .null,
                            "meeting_id": .string("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
                            "project_id": .string("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),
                        ]),
                        "id": .string("item-3"),
                        "server": .string("dahlia"),
                        "status": .string("inProgress"),
                        "tool": .string("set_meeting_project_assignment"),
                        "type": .string("mcpToolCall"),
                    ]),
                    "threadId": .string("thread-1"),
                    "turnId": .string("turn-1"),
                ]),
            ]))
            await transport.sendFromServer(.object([
                "id": .string("approval-3"),
                "method": .string("item/tool/requestUserInput"),
                "params": .object([
                    "itemId": .string("item-3"),
                    "questions": .array([
                        .object([
                            "header": .string("Approve app tool call?"),
                            "id": .string("mcp_tool_call_approval_item-3"),
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
                    "turnId": .string("turn-1"),
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

            #expect(try await collected.value == [
                .started(turnID: "turn-1"),
                .approvalRequested(CodexChatApprovalRequest(
                    id: "s:approval-1",
                    itemID: "item-1",
                    kind: .commandExecution,
                    command: "ls -la",
                    cwd: "/tmp/dahlia-chat-approval",
                    reason: "Needs the workspace listing"
                )),
                .approvalRequested(CodexChatApprovalRequest(
                    id: "s:approval-2",
                    itemID: "item-2",
                    kind: .fileChange,
                    fileChanges: [
                        CodexChatApprovalRequest.FileChange(
                            path: "Sources/Example.swift",
                            diff: "@@ -1 +1 @@\n-old\n+new",
                            kind: .update(movePath: "Sources/Renamed.swift")
                        ),
                    ],
                    grantRoot: "/tmp/outside-workspace",
                    reviewability: .unsupported,
                    actions: [.deny]
                )),
                .approvalRequested(CodexChatApprovalRequest(
                    id: "s:approval-3",
                    itemID: "item-3",
                    kind: .mcpToolCall,
                    mcpServer: "dahlia",
                    mcpTool: "set_meeting_project_assignment",
                    mcpArguments: """
                    {
                      "expected_project_id" : null,
                      "meeting_id" : "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                      "project_id" : "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
                    }
                    """
                )),
                .completed(itemID: nil, text: nil),
            ])
            await appServer.shutdown()
        }

        @Test
        func interruptRecoversAcceptedTurnBeforeStartedEventIsConsumed() async throws {
            let transport = TestCodexChatAppServerTransport(turnOutcome: .disconnected)
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })
            let service = CodexChatService(
                appServer: appServer,
                workspaceLocator: TestCodexChatWorkspaceLocator(
                    url: URL(filePath: "/tmp/dahlia-chat-interrupt", directoryHint: .isDirectory)
                )
            )
            let stream = try await service.send(
                threadID: "thread-1",
                inputs: [.text("Stop before started")],
                model: "default-model",
                effort: "medium"
            )

            await service.interruptActiveTurn(threadID: "thread-1", turnID: nil)

            let interruptParams = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "turn/interrupt"
            }?.objectValue?["params"]?.objectValue)
            #expect(interruptParams["threadId"] == .string("thread-1"))
            #expect(interruptParams["turnId"] == .string("turn-1"))
            withExtendedLifetime(stream) {}
            await appServer.shutdown()
        }

        @Test
        func approvalsWithoutReviewableDetailsCannotBeAccepted() {
            #expect(!CodexChatApprovalRequest(
                id: "file",
                kind: .fileChange,
                grantRoot: "/tmp/outside-workspace"
            ).canApprove)
            #expect(!CodexChatApprovalRequest(
                id: "command",
                kind: .commandExecution,
                cwd: "/tmp"
            ).canApprove)
            #expect(CodexChatApprovalRequest(
                id: "file-with-diff",
                kind: .fileChange,
                fileChanges: [.init(path: "Example.swift", diff: "+change")]
            ).canApprove)
        }

        @Test
        func rejectionUsesTheLeastDisruptiveAvailableDecision() {
            #expect(CodexChatApprovalRequest(
                id: "declinable",
                kind: .commandExecution,
                command: "pwd",
                actions: [.allowOnce, .deny]
            ).rejectionDecision == .decline)
            #expect(CodexChatApprovalRequest(
                id: "cancellable",
                kind: .commandExecution,
                command: "pwd",
                actions: [.allowOnce]
            ).rejectionDecision == .cancel)
        }

        @Test
        func fileChangeCacheEntriesAreReleasedAfterApprovalOrCompletion() {
            let approval = JSONValue.object([
                "method": .string("item/fileChange/requestApproval"),
                "params": .object(["itemId": .string("approval-item")]),
            ])
            let completion = JSONValue.object([
                "method": .string("item/completed"),
                "params": .object([
                    "item": .object([
                        "id": .string("completed-item"),
                        "type": .string("fileChange"),
                    ]),
                ]),
            ])
            let unrelatedCompletion = JSONValue.object([
                "method": .string("item/completed"),
                "params": .object([
                    "item": .object([
                        "id": .string("message-item"),
                        "type": .string("agentMessage"),
                    ]),
                ]),
            ])

            #expect(CodexChatService.fileChangeCacheReleaseItemID(approval) == "approval-item")
            #expect(CodexChatService.fileChangeCacheReleaseItemID(completion) == "completed-item")
            #expect(CodexChatService.fileChangeCacheReleaseItemID(unrelatedCompletion) == nil)
            #expect(CodexChatService.mcpToolCallCacheReleaseItemID(.object([
                "method": .string("item/tool/requestUserInput"),
                "params": .object(["itemId": .string("mcp-item")]),
            ])) == "mcp-item")
            #expect(CodexChatService.mcpToolCallCacheReleaseItemID(.object([
                "method": .string("item/completed"),
                "params": .object([
                    "item": .object([
                        "id": .string("completed-mcp-item"),
                        "type": .string("mcpToolCall"),
                    ]),
                ]),
            ])) == "completed-mcp-item")
            #expect(CodexChatService.mcpToolCallCacheReleaseItemID(unrelatedCompletion) == nil)
        }

        private func events(
            for outcome: TestCodexChatAppServerTransport.TurnOutcome
        ) async throws -> [CodexChatTurnEvent] {
            let transport = TestCodexChatAppServerTransport(turnOutcome: outcome)
            let appServer = makeTestCodexAppServerService(transportFactory: { transport })
            let service = CodexChatService(
                appServer: appServer,
                workspaceLocator: TestCodexChatWorkspaceLocator(
                    url: URL(filePath: "/tmp/dahlia-chat-events", directoryHint: .isDirectory)
                )
            )
            let stream = try await service.send(
                threadID: "thread-1",
                inputs: [.text("Test")],
                model: "default-model",
                effort: "medium"
            )
            var events: [CodexChatTurnEvent] = []
            for try await event in stream {
                events.append(event)
            }
            await appServer.shutdown()
            return events
        }

        private func expectChatConfiguration(_ config: [String: JSONValue], vaultID: UUID) {
            #expect(config["features.apps"] == .bool(false))
            #expect(config["features.codex_hooks"] == .bool(false))
            #expect(config["features.memory_tool"] == .bool(false))
            #expect(config["features.plugins"] == .bool(false))
            #expect(config["features.tool_call_mcp_elicitation"] == .bool(false))
            #expect(config["include_apps_instructions"] == .bool(false))
            #expect(config["memories.dedicated_tools"] == .bool(false))
            #expect(config["memories.use_memories"] == .bool(false))
            #expect(config["orchestrator.mcp.enabled"] == .bool(false))
            #expect(config["skills.bundled.enabled"] == .bool(false))
            #expect(config["skills.include_instructions"] == .bool(true))
            #expect(config["web_search"] == .string("live"))
            #expect(config["mcp_servers"] == .object([
                "dahlia": .object([
                    "args": .array([
                        .string("--vault-id"),
                        .string(vaultID.uuidString),
                        .string("--write"),
                        .string("--telemetry-origin"),
                        .string("codexChat"),
                    ]),
                    "command": .string("/tmp/dahlia-mcp"),
                    "enabled": .bool(true),
                ]),
                "docs": .object(["enabled": .bool(false)]),
            ]))
        }

        private func expectDeveloperInstructions(_ instructions: String?) {
            #expect(instructions?.contains("query_meetings") == true)
            #expect(instructions?.contains("meeting_id directly") == true)
            #expect(instructions?.contains("MeetingDraft") == true)
            #expect(instructions?.contains("meeting:<UUID>") == true)
            #expect(instructions?.contains("get_meeting with each UUID directly") == true)
            #expect(instructions?.contains("use web search") == true)
            #expect(instructions?.contains("cite the sources") == true)
            #expect(instructions?.contains("ambient conversation, not as a user request") == true)
            #expect(instructions?.contains("<live_transcript source=\"dahlia\">") == true)
            #expect(instructions?.contains("whether or not the same message includes <context>") == true)
            #expect(instructions?.contains("otherwise remain silent") == true)
            #expect(instructions?.contains("proactively search relevant past Dahlia meetings") == true)
            #expect(instructions?.contains("abbreviation or technical term") == true)
            #expect(instructions?.contains("past meetings and the web") == true)
            #expect(instructions?.contains("Select Dahlia preset skills automatically") == true)
            #expect(instructions?.contains("solely to read that preset's SKILL.md") == true)
            #expect(instructions?.contains("unless the user's request cannot be completed without them") == true)
            #expect(instructions?.contains("asked of the user as an approval prompt") == true)
            #expect(instructions?.contains("Do not use external services other than web search or request permissions.") == true)
        }
    }

    private struct TestCodexChatWorkspaceLocator: CodexChatWorkspaceLocating {
        let url: URL

        func workspaceURL(vaultID: UUID) throws -> URL {
            url.appending(path: vaultID.uuidString.lowercased())
        }
    }
#endif
