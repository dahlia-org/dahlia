#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @Suite(.timeLimit(.minutes(1)))
    struct SkillCuratorRuntimeTests {
        @Test(arguments: ["unauthorized", "errorAfterIntermediate", "messageAbort", "settledAbort", "emptyFinal", "success", "budget", "noMessage", "eof"])
        func consolidationRecordsTerminalOutcome(scenario: String) async throws {
            let script = events(scenario)
            let transports = TestPiTransportLog()
            let provider = CodexRuntimeProvider.databricks(connectionID: .v7())
            let pi = TestPiRuntime(provider: provider) { options in
                let transport = TestPiTransport { command in
                    guard let id = command["id"] else { return [] }
                    if command["type"]?.stringValue == "get_commands" {
                        return [TestPiTransport.response(id: id, data: .object(["commands": .array([])]))]
                    }
                    return [TestPiTransport.response(id: id)] + (command["type"]?.stringValue == "prompt" ? script : [])
                }
                if options.mode == .chat { transports.append(transport) }
                return transport
            }
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            let account = provider.accountKey
            UserDefaults.standard.set(true, forKey: SkillCuratorSettings.consolidateKey(account))
            defer { UserDefaults.standard.removeObject(forKey: SkillCuratorSettings.consolidateKey(account)) }
            let locator = PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL)
            let root = try locator.agentURL(for: provider).appending(path: "skills/sample")
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
            let run = Task { await service.runCurator(provider: provider) }
            if scenario == "eof" {
                let transport = await transports.transport(at: 0)
                _ = await transport.command("prompt")
                await transport.close()
            }
            await run.value
            let saved = try await db.read { try AgentSystemRunRecord.fetchOne($0) }
            let record = try #require(saved)
            let completed = scenario == "emptyFinal" || scenario == "success"
            let interrupted = scenario == "messageAbort" || scenario == "settledAbort"
            #expect(record.status == (completed ? "completed" : interrupted ? "interrupted" : "failed"))
            #expect(record.finishedAt != nil)
            #expect(record.report == (scenario == "success" ? "Final report" : ""))
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
