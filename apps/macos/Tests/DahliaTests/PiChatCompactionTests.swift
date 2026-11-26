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
            let pi = TestPiRuntime { options in
                options.mode == .chat
                    ? transport
                    : TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "openai", id: "gpt-test")]))
            }
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
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
            let thread = try await chat.startThread(model: nil, effort: "medium")
            let turn = try await chat.beginTurn(threadID: thread.id, inputs: [.text(text)], model: nil, effort: "medium", approvalMethod: .ask)
            var received: [CodexChatTurnEvent] = []
            for try await event in turn.events {
                received.append(event)
            }
            let saved = try await chat.loadThread(id: thread.id).messages
            return try (received, saved, store.latestRun(threadID: thread.id), transport)
        }

        @Test(arguments: ["succeeded", "failed", "stopped"])
        func compactCommandRunsPiCompactionAndSavesItsResult(outcome: String) async throws {
            let compaction = outcome == "succeeded" ? CodexChatCompaction(tokensBefore: 43700, tokensAfter: 17200) : nil
            let extra: [String: JSONValue] = switch outcome {
            case "succeeded": ["result": .object(["tokensBefore": .number(43700), "estimatedTokensAfter": .number(17200)])]
            case "failed": ["errorMessage": .string("Compaction failed: Nothing to compact")]
            default: [:]
            }
            let result = try await Self.run(
                "/compact  Keep the decisions\n",
                events: [Self.compactionStart, Self.compactionEnd(aborted: outcome == "stopped", extra: extra)]
            )
            let last: CodexChatTurnEvent = switch outcome {
            case "succeeded": .completed(itemID: nil, text: nil)
            case "failed": .failed(message: "Compaction failed: Nothing to compact")
            default: .interrupted
            }
            #expect(Array(result.events.dropFirst()) == [.compactionStarted, .compactionEnded(compaction), last])
            #expect(await result.transport.command("compact")["customInstructions"] == .string("Keep the decisions"))
            #expect(await result.transport.commands.allSatisfy { $0["type"] != .string("prompt") })
            #expect(result.saved.map(\.role) == [.user] + (compaction.map { [.compaction($0)] } ?? []))
            #expect(result.run?.status == ["succeeded": "completed", "failed": "failed"][outcome] ?? "interrupted")
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
