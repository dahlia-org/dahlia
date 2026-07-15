import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct CodexChatServiceTests {
        @Test
        func persistentChatOmitsOutputSchemaAndReplaysEarlyDeltas() async throws {
            let transport = TestCodexChatAppServerTransport()
            let appServer = CodexAppServerService(transportFactory: { transport })
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
                text: "Hi",
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
                .delta(itemID: "item-1", text: "Hello"),
                .completed(itemID: "item-1", text: "Hello"),
                .completed(itemID: nil, text: nil),
            ])

            let messages = await transport.messages()
            let threadParams = try #require(messages.first {
                $0.objectValue?["method"]?.stringValue == "thread/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(threadParams["ephemeral"] == .bool(false))
            #expect(threadParams["approvalPolicy"] == .string("never"))
            #expect(threadParams["sandbox"] == .string("read-only"))
            #expect(threadParams["cwd"] == .string(workspace.appending(path: vaultID.uuidString.lowercased()).path))
            let config = try #require(threadParams["config"]?.objectValue)
            #expect(config["features.apps"] == .bool(false))
            #expect(config["features.codex_hooks"] == .bool(false))
            #expect(config["features.memory_tool"] == .bool(false))
            #expect(config["features.plugins"] == .bool(false))
            #expect(config["include_apps_instructions"] == .bool(false))
            #expect(config["memories.dedicated_tools"] == .bool(false))
            #expect(config["memories.use_memories"] == .bool(false))
            #expect(config["orchestrator.mcp.enabled"] == .bool(false))
            #expect(config["skills.include_instructions"] == .bool(false))
            #expect(config["mcp_servers"] == .object([
                "dahlia": .object([
                    "args": .array([.string("--vault-id"), .string(vaultID.uuidString)]),
                    "command": .string("/tmp/dahlia-mcp"),
                    "enabled": .bool(true),
                ]),
                "docs": .object(["enabled": .bool(false)]),
            ]))
            #expect(threadParams["developerInstructions"]?.stringValue?.contains("query_meetings") == true)

            let turnParams = try #require(messages.first {
                $0.objectValue?["method"]?.stringValue == "turn/start"
            }?.objectValue?["params"]?.objectValue)
            #expect(turnParams["outputSchema"] == nil)
            #expect(turnParams["effort"] == .string("high"))
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
            let appServer = CodexAppServerService(transportFactory: { transport })
            let service = CodexChatService(
                appServer: appServer,
                workspaceLocator: TestCodexChatWorkspaceLocator(
                    url: URL(filePath: "/tmp/dahlia-chat-disconnect", directoryHint: .isDirectory)
                )
            )
            let stream = try await service.send(
                threadID: "thread-1",
                text: "Disconnect",
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
        func historyUsesExactWorkspaceAndBundledCodexSourceAndRestoresMessages() async throws {
            let transport = TestCodexChatAppServerTransport()
            let appServer = CodexAppServerService(transportFactory: { transport })
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
            #expect(loaded.messages.map(\.text) == ["Question", "Answer"])
            #expect(resumed.model == "default-model")
            #expect(resumed.reasoningEffort == "high")

            let listParams = try #require(await transport.messages().first {
                $0.objectValue?["method"]?.stringValue == "thread/list"
            }?.objectValue?["params"]?.objectValue)
            #expect(listParams["cwd"] == .array([
                .string(workspace.appending(path: vaultID.uuidString.lowercased()).path),
            ]))
            #expect(listParams["sourceKinds"] == .array([.string("vscode")]))
            #expect(listParams["sortKey"] == .string("recency_at"))
            #expect(listParams["sortDirection"] == .string("desc"))
            await appServer.shutdown()
        }

        private func events(
            for outcome: TestCodexChatAppServerTransport.TurnOutcome
        ) async throws -> [CodexChatTurnEvent] {
            let transport = TestCodexChatAppServerTransport(turnOutcome: outcome)
            let appServer = CodexAppServerService(transportFactory: { transport })
            let service = CodexChatService(
                appServer: appServer,
                workspaceLocator: TestCodexChatWorkspaceLocator(
                    url: URL(filePath: "/tmp/dahlia-chat-events", directoryHint: .isDirectory)
                )
            )
            let stream = try await service.send(
                threadID: "thread-1",
                text: "Test",
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
    }

    private struct TestCodexChatWorkspaceLocator: CodexChatWorkspaceLocating {
        let url: URL

        func workspaceURL(vaultID: UUID) throws -> URL {
            url.appending(path: vaultID.uuidString.lowercased())
        }
    }
#endif
