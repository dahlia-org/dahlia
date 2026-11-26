import DahliaRuntimeSupport
import Foundation
@testable import Dahlia

#if canImport(Testing)
    import Testing

    struct PiChatCompactionTests {
        private static let compactionStart: JSONValue = .object(["type": .string("compaction_start"), "reason": .string("manual")])

        private static func compactionEnd(reason: String = "manual", aborted: Bool = false, extra: [String: JSONValue]) -> JSONValue {
            .object(["type": .string("compaction_end"), "reason": .string(reason), "aborted": .bool(aborted), "willRetry": .bool(false)]
                .merging(extra) { $1 })
        }

        /// Runs one turn on a chat process whose `prompt` and `compact` commands write `events` before their answers.
        private static func run(
            _ text: String, events: [JSONValue]
        ) async throws -> (events: [CodexChatTurnEvent], saved: [CodexChatMessage], run: ChatRunRecord?, transport: TestPiTransport) {
            let transport = TestPiTransport { command in
                guard let id = command["id"] else { return [] }
                if command["type"]?.stringValue == "compact" {
                    // An empty script stands for a Pi that rejects the command without compacting.
                    return events + [events.isEmpty ? Self.rejection(id: id) : TestPiTransport.response(id: id)]
                }
                let response = TestPiTransport.response(id: id, data: .object(["disposition": .string("started")]))
                return command["type"]?.stringValue == "prompt" ? [response] + events : [response]
            }
            let (pi, store, chat) = try Self.fixture(transport: transport)
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            let thread = try await chat.startThread(model: nil, effort: "medium")
            let turn = try await chat.beginTurn(threadID: thread.id, inputs: [.text(text)], model: nil, effort: "medium", approvalMethod: .ask)
            var received: [CodexChatTurnEvent] = []
            for try await event in turn.events {
                received.append(event)
            }
            let saved = try await chat.loadThread(id: thread.id).messages
            return try (received, saved, store.latestRun(threadID: thread.id), transport)
        }

        private static func fixture(transport: TestPiTransport) throws -> (TestPiRuntime, ChatThreadStore, PiChatService) {
            let pi = TestPiRuntime { options in
                options.mode == .chat
                    ? transport
                    : TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "openai", id: "gpt-test")]))
            }
            let store = try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            let chat = PiChatService(
                runtime: pi.service,
                historyStore: store,
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: { AgentMCPSettings() },
                fileAccessSettings: { PiFileAccessSettings() }
            )
            return (pi, store, chat)
        }

        @Test(arguments: ["new", "empty", "reply", "pagedReply"])
        func compactSuggestionUsesCompleteReplyHistory(state: String) async throws {
            let transport = TestPiTransport { command in
                guard command["type"] == .string("get_commands"), let id = command["id"] else {
                    return TestPiTransport.acknowledge(command)
                }
                return [TestPiTransport.response(id: id, data: .object(["commands": .array([])]))]
            }
            let (pi, store, chat) = try Self.fixture(transport: transport)
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            let threadID = try await state == "new" ? nil : chat.startThread(model: nil, effort: "medium").id
            if let threadID, state == "reply" || state == "pagedReply" {
                try store.appendItems(threadID: threadID, items: [
                    ChatHistoryCodec.message(["role": .string("assistant"), "content": .string("Answer")]),
                ])
                if state == "pagedReply" {
                    try store.appendItems(threadID: threadID, items: (0 ..< 40).map { _ in ChatHistoryCodec.user([.text("/mcp")]) })
                    #expect(try await chat.loadThread(id: threadID).messages.allSatisfy { $0.role != .assistant })
                }
            }
            let commands = try await chat.commands(threadID: threadID)
            #expect(commands.contains { $0.name == "compact" } == (state == "reply" || state == "pagedReply"))
            await pi.service.shutdown()
        }

        @Test(arguments: [CodexAppServerInput.imageMetadata("Screenshot"), .imageDataURI("data:image/png;base64,AQ==")])
        func compactRejectsImageInputsBeforeCommitting(attachment: CodexAppServerInput) async throws {
            let transport = TestPiTransport()
            let (pi, store, chat) = try Self.fixture(transport: transport)
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            let thread = try await chat.startThread(model: nil, effort: "medium")
            do {
                _ = try await chat.beginTurn(
                    threadID: thread.id, inputs: [.text("/compact"), attachment], model: nil, effort: "medium", approvalMethod: .ask
                )
                Issue.record("An image-bearing compact request was accepted")
            } catch {
                #expect(error.localizedDescription == L10n.chatCompactDoesNotSupportImages)
            }
            #expect(try store.latestRun(threadID: thread.id) == nil)
            #expect(try store.messagePage(threadID: thread.id).messages.isEmpty)
            #expect(await transport.commands.allSatisfy { $0["type"] != .string("compact") && $0["type"] != .string("prompt") })
            await pi.service.shutdown()
        }

        @Test(arguments: ["/compact", "/mcp", "Question"])
        func attachingRestoresTheCommandDeliveryContract(text: String) async throws {
            let transport = TestPiTransport { command in
                command["type"] == .string("compact") ? [] : TestPiTransport.acknowledge(command)
            }
            let (pi, _, chat) = try Self.fixture(transport: transport)
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            let thread = try await chat.startThread(model: nil, effort: "medium")
            let turn = try await chat.beginTurn(threadID: thread.id, inputs: [.text(text)], model: nil, effort: "medium", approvalMethod: .ask)
            let attached = try #require(await chat.attach(threadID: thread.id))
            #expect(turn.isCommand == text.hasPrefix("/"))
            #expect(attached.isCommand == turn.isCommand)
            await chat.closeSession(thread.id)
            await pi.service.shutdown()
        }

        @Test(arguments: ["succeeded", "failed", "nothing", "already", "stopped"])
        func compactCommandRunsPiCompactionAndSavesItsResult(outcome: String) async throws {
            let compaction = outcome == "succeeded" ? CodexChatCompaction(tokensBefore: 43700, tokensAfter: 17200) : nil
            let extra: [String: JSONValue] = switch outcome {
            case "succeeded": ["result": .object(["tokensBefore": .number(43700), "estimatedTokensAfter": .number(17200)])]
            case "failed": ["errorMessage": .string("Compaction failed: Request timed out")]
            case "nothing": ["errorMessage": .string("Compaction failed: Nothing to compact (session too small)")]
            case "already": ["errorMessage": .string("Compaction failed: Already compacted")]
            default: [:]
            }
            let result = try await Self.run(
                "/compact  Keep the decisions\n",
                events: [Self.compactionStart, Self.compactionEnd(aborted: outcome == "stopped", extra: extra)]
            )
            let last: [CodexChatTurnEvent] = switch outcome {
            case "succeeded": [.completed(itemID: nil, text: nil)]
            case "failed": [.failed(message: "Compaction failed: Request timed out")]
            case "nothing", "already": [.notice(message: L10n.chatNothingToCompact, level: .info), .completed(itemID: nil, text: nil)]
            default: [.interrupted]
            }
            #expect(Array(result.events.dropFirst()) == [.compactionStarted, .compactionEnded(compaction)] + last)
            #expect(await result.transport.command("compact")["customInstructions"] == .string("Keep the decisions"))
            #expect(await result.transport.commands.allSatisfy { $0["type"] != .string("prompt") })
            #expect(result.saved.map(\.role) == [.user] + (compaction.map { [.compaction($0)] } ?? []))
            #expect(result.run?.status == ["succeeded": "completed", "nothing": "completed", "already": "completed", "failed": "failed"][outcome] ?? "interrupted")
        }

        private static func rejection(id: JSONValue) -> JSONValue {
            .object([
                "type": .string("response"), "id": id, "command": .string("compact"),
                "success": .bool(false), "error": .string("Unknown command: compact"),
            ])
        }

        @Test
        func compactCommandPiRejectsWithoutCompactingFailsTheTurn() async throws {
            let result = try await Self.run("/compact", events: [])
            guard case let .failed(message)? = result.events.last else {
                Issue.record("The turn did not fail: \(result.events)")
                return
            }
            #expect(message?.contains("Unknown command: compact") == true)
            #expect(result.saved.map(\.role) == [.user])
            #expect(result.run?.status == "failed")
        }

        @Test
        func compactionPiStartsOnItsOwnLeavesTheTurnRunning() async throws {
            let result = try await Self.run("Hello", events: [
                Self.compactionStart,
                Self.compactionEnd(reason: "threshold", extra: [
                    "result": .object(["tokensBefore": .number(900), "estimatedTokensAfter": .number(300)]),
                ]),
                TestPiTransport.assistantEnd("Done"),
                TestPiTransport.settled(),
            ])
            let compaction = CodexChatCompaction(tokensBefore: 900, tokensAfter: 300)
            #expect(result.events.contains(.compactionEnded(compaction)))
            #expect(result.events.last == .completed(itemID: nil, text: nil))
            #expect(result.saved.map(\.role) == [.user, .compaction(compaction), .assistant])
            #expect(result.run?.status == "completed")
        }

        @Test
        func compactInstructionsMatchOnlyTheCompactCommand() {
            #expect(PiChatService.compactInstructions([.text("/compact")])?.isEmpty == true)
            #expect(PiChatService.compactInstructions([.text("/compact Focus\non code")]) == "Focus\non code")
            #expect(PiChatService.compactInstructions([.text("/compaction")]) == nil)
            #expect(PiChatService.compactInstructions([.text("Please /compact")]) == nil)
        }
    }
#endif
