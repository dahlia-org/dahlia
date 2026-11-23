#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import os
    import Testing
    @testable import Dahlia

    @Suite(.timeLimit(.minutes(1)))
    struct SkillCuratorRuntimeTests {
        // Every case uses the app's one account, whose curator setting lives in the shared defaults.
        @Test(.serialized, arguments: [
            "unauthorized", "errorAfterIntermediate", "messageAbort", "settledAbort", "emptyFinal", "success",
            "budget", "noMessage", "eof", "consolidationOff", "drainDuringTransitions", "drainDuringConsolidation", "accountRemoved",
        ])
        func consolidationRecordsTerminalOutcome(scenario: String) async throws {
            let script = events(scenario)
            let transports = TestPiTransportLog()
            // pi-hermes-skills answers `/hermes-curator` through the bridge before Pi reports the command handled.
            let report: JSONValue = .object([
                "counts": .object(["archived": .number(1), "markedStale": .number(0), "reactivated": .number(0)]),
                "candidates": .string("Agent-created skills (1):\n\n- sample  provenance=agent"),
            ])
            let pendingCommand = OSAllocatedUnfairLock<JSONValue?>(initialState: nil)
            let pi = TestPiRuntime { options in
                let transport = TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    switch command["type"]?.stringValue {
                    case "get_commands":
                        return [TestPiTransport.response(id: id, data: .object(["commands": .array([])]))]
                    case "extension_ui_response":
                        return pendingCommand.withLock { pending in
                            defer { pending = nil }
                            return pending.map { [TestPiTransport.response(id: $0, data: .object(["disposition": .string("handled")]))] } ?? []
                        }
                    case "prompt" where command["message"]?.stringValue == "/hermes-curator":
                        pendingCommand.withLock { $0 = id }
                        return scenario == "drainDuringTransitions" ? [] : [TestPiTransport.bridgeRequest(
                            id: "report",
                            method: "curatorReport",
                            payload: report
                        )]
                    default:
                        return [TestPiTransport.response(id: id)] + (command["type"]?.stringValue == "prompt" ? script : [])
                    }
                }
                if options.mode == .chat { transports.append(transport) }
                return transport
            }
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            let account = AppAccount.key
            UserDefaults.standard.set(!["consolidationOff", "drainDuringTransitions"].contains(scenario), forKey: SkillCuratorSettings.consolidateKey(account))
            defer { UserDefaults.standard.removeObject(forKey: SkillCuratorSettings.consolidateKey(account)) }
            let locator = PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL)
            let root = try locator.agentURL().appending(path: "skills/sample")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("---\nname: sample\ndescription: Use when testing.\n---\nFollow the steps.".utf8).write(to: root.appending(path: "SKILL.md"))
            let db = try AppDatabaseManager(path: ":memory:").dbQueue
            try await db.write {
                try $0.execute(
                    sql: "INSERT INTO agent_skill_states(accountID,name,createdBy,createdAt) VALUES(?,'sample','agent',?)",
                    arguments: [account, Date()]
                )
            }
            let service = PiChatService(runtime: pi.service, historyStore: ChatThreadStore(dbQueue: db), agentLocator: locator)
            let run = Task { await service.runCurator() }
            if scenario == "drainDuringTransitions" {
                let transport = await transports.transport(at: 0)
                _ = await transport.command("prompt")
                await service.drainLearningWork()
                #expect(await !transport.isClosed)
                await transport.emit(TestPiTransport.bridgeRequest(id: "report", method: "curatorReport", payload: report))
            } else if scenario == "drainDuringConsolidation" {
                let transport = await transports.transport(at: 0)
                _ = await transport.command { $0["type"]?.stringValue == "prompt" && $0["message"]?.stringValue != "/hermes-curator" }
                UserDefaults.standard.set(false, forKey: SkillCuratorSettings.consolidateKey(account))
                await service.drainLearningWork()
                #expect(await transport.isClosed)
            }
            if scenario == "accountRemoved" {
                let transport = await transports.transport(at: 0)
                _ = await transport.command { $0["type"]?.stringValue == "prompt" && $0["message"]?.stringValue != "/hermes-curator" }
                try await MeetingRepository(dbQueue: db).deleteDahliaAccountConnection(id: #require(UUID(uuidString: account)))
                await transport.emit(TestPiTransport.assistantEnd("Finished after removal."))
                await transport.emit(TestPiTransport.settled())
            }
            if scenario == "eof" {
                let transport = await transports.transport(at: 0)
                _ = await transport.command("prompt")
                await transport.close()
            }
            await run.value
            let saved = try await db.read { try AgentSystemRunRecord.fetchOne($0) }
            if scenario == "accountRemoved" {
                #expect(saved == nil)
                #expect(await transports.allClosed())
                return
            }
            let record = try #require(saved)
            let completed = ["emptyFinal", "success", "consolidationOff", "drainDuringTransitions"].contains(scenario)
            let interrupted = ["messageAbort", "settledAbort", "drainDuringConsolidation"].contains(scenario)
            #expect(record.status == (completed ? "completed" : interrupted ? "interrupted" : "failed"))
            #expect(record.finishedAt != nil)
            #expect(record.report == (scenario == "success" ? "Final report" : ""))
            if completed { #expect(record.summary.hasPrefix(L10n.agentCuratorAutoSummary(archived: 1, stale: 0, reactivated: 0))) }
            if ["consolidationOff", "drainDuringTransitions"]
                .contains(scenario) { #expect(record.summary.hasSuffix(L10n.agentCuratorConsolidationOff)) }
            if scenario == "unauthorized" || scenario == "errorAfterIntermediate" {
                #expect(record.summary.contains(PiRuntimeError.notLoggedIn.localizedDescription))
            }
            #expect(await transports.allClosed())
        }

        private func events(_ scenario: String) -> [JSONValue] {
            let intermediate = TestPiTransport.assistantEnd("Intermediate report", stopReason: "toolUse")
            let failure = TestPiTransport.assistantEnd("", stopReason: "error", errorMessage: "401 Unauthorized")
            switch scenario {
            case "unauthorized": return [failure, TestPiTransport.settled()]
            case "errorAfterIntermediate": return [intermediate, failure, TestPiTransport.settled()]
            case "messageAbort": return [intermediate, TestPiTransport.assistantEnd("", stopReason: "aborted"), TestPiTransport.settled()]
            case "settledAbort": return [intermediate, TestPiTransport.settled(aborted: true)]
            case "emptyFinal": return [intermediate, TestPiTransport.assistantEnd(""), TestPiTransport.settled()]
            case "success": return [intermediate, TestPiTransport.assistantEnd("Final report"), TestPiTransport.settled()]
            case "budget": return Array(repeating: intermediate, count: 101)
            case "noMessage": return [TestPiTransport.settled()]
            default: return []
            }
        }
    }
#endif
