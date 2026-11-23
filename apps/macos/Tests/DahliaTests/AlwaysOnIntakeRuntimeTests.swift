#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @Suite(.timeLimit(.minutes(1)))
    struct AlwaysOnIntakeRuntimeTests {
        private struct Fixture {
            let pi: TestPiRuntime
            let service: PiChatService
            let db: any DatabaseWriter
            let source: String
            let transports: TestPiTransportLog
        }

        private static let twoItems: JSONValue = .object(["items": .array([
            .object(["external_id": .string("m1"), "topic_key": .string("t1"), "url": .string("https://mail.example.com/m1")]),
            .object(["external_id": .string("m2"), "topic_key": .string("t2")]),
        ])])

        /// Like real Pi, the fake makes each bridge call in turn and settles only after Dahlia answered the last one.
        private func fixture(
            calls: [(String, JSONValue)],
            ending: [JSONValue],
            service: String = "system.ai.gmail",
            registryChange: String? = nil,
            readSucceeded: Bool = true
        ) throws -> Fixture {
            let calls = readSucceeded ? [("intakeSeen", JSONValue.object(["ids": .array([])]))] + calls : calls
            let provider = CodexRuntimeProvider.databricks(connectionID: .v7())
            let gateway = AgentMCPProvider(workspaceURL: URL(string: "https://dbc-1.cloud.databricks.com")!)
            let settings = AgentMCPSettings(
                providers: [gateway], servers: [AgentMCPServer(id: .v7(), name: "gmail", providerID: gateway.id, service: service)]
            )
            let registry = Mutex(settings)
            @Sendable func replaceRegistration(_ settings: inout AgentMCPSettings) {
                settings.servers = [AgentMCPServer(id: .v7(), name: "gmail", providerID: gateway.id, service: service)]
            }
            if registryChange == "before" { registry.withLock { replaceRegistration(&$0) } }
            let transports = TestPiTransportLog()
            let pi = TestPiRuntime(provider: provider) { _ in
                if registryChange == "during" { registry.withLock { replaceRegistration(&$0) } }
                let transport = TestPiTransport { command in
                    switch command["type"]?.stringValue {
                    case "extension_ui_response":
                        let answered = Int(command["id"]?.stringValue?.dropFirst() ?? "") ?? 0
                        return answered < calls.count
                            ? [TestPiTransport.bridgeRequest(id: "r\(answered + 1)", method: calls[answered].0, payload: calls[answered].1)]
                            : ending
                    case "get_commands":
                        return [TestPiTransport.response(id: command["id"] ?? .null, data: .object(["commands": .array([])]))]
                    case "prompt":
                        return [
                            TestPiTransport.response(id: command["id"] ?? .null),
                            TestPiTransport.bridgeRequest(id: "r1", method: calls[0].0, payload: calls[0].1),
                        ]
                    default: return command["id"].map { [TestPiTransport.response(id: $0)] } ?? []
                    }
                }
                transports.append(transport)
                return transport
            }
            let db = try AppDatabaseManager(path: ":memory:").dbQueue
            let source = UUID.v7().uuidString
            try db.write {
                try AgentSourceRecord(
                    id: source, accountID: provider.accountKey, name: "Mail", server: "gmail", instructions: "Unread mail",
                    intervalMinutes: 15, sieve: "candidate", allowedSenders: "[]", cursor: nil, enabled: true,
                    gapDetectedAt: nil, lastIntakeAt: nil, createdAt: .now, updatedAt: .now, connectionID: settings.connectionID(for: "gmail")!
                ).insert($0)
            }
            let chat = PiChatService(
                runtime: pi.service, historyStore: ChatThreadStore(dbQueue: db),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL), mcpSettings: { _ in registry.withLock { $0 } }
            )
            return Fixture(pi: pi, service: chat, db: db, source: source, transports: transports)
        }

        private func drain(_ fixture: Fixture, at now: Date = .now) async {
            await fixture.service.drainAlwaysOn(now: now)
            await fixture.service.intakeTask?.value
        }

        private func saved(_ fixture: Fixture) async throws -> (AgentSourceRecord, [AgentSystemRunRecord], [AgentEventRecord]) {
            try await fixture.db.read { db in
                try (
                    #require(try AgentSourceRecord.fetchOne(db, key: fixture.source)),
                    // The Router also runs once intake recorded events; these tests look at intake alone.
                    AgentSystemRunRecord.fetchAll(db, sql: "SELECT * FROM agent_system_runs WHERE task='intake' ORDER BY startedAt, id"),
                    AgentEventRecord.fetchAll(db, sql: "SELECT * FROM agent_event_inbox ORDER BY externalID")
                )
            }
        }

        @Test(arguments: ["success", "unauthorized", "refused", "mcpError"])
        func readPositionMovesOnlyAfterACleanRun(scenario: String) async throws {
            var calls = [
                ("intakeSeen", JSONValue.object(["ids": .array([.string("m1"), .string("m2")])])),
                (
                    "eventRecord",
                    scenario == "refused" ? .object(["items": .array([.object(["subject": .string("no id")])])]) : Self.twoItems
                ),
            ]
            if scenario == "mcpError" { calls.insert(("intakeReadFailed", .object([:])), at: 0) }
            let ending = scenario == "unauthorized"
                ? [TestPiTransport.assistantEnd("", stopReason: "error", errorMessage: "401 Unauthorized"), TestPiTransport.settled()]
                : [TestPiTransport.assistantEnd("Recorded."), TestPiTransport.settled()]
            let fixture = try fixture(calls: calls, ending: ending)
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }

            await drain(fixture)

            let launch = try #require(fixture.pi.launches.all.first { $0.profile == .intake })
            #expect(launch.profile == .intake && launch.arguments.contains("event_record,mcp__gmail__*"))
            #expect(launch.environment["DAHLIA_PI_MCP_SERVERS"] == #"["gmail"]"#)
            let (source, runs, events) = try await saved(fixture)
            let run = try #require(runs.first)
            #expect(run.task == "intake" && run.finishedAt != nil)
            #expect(events.count == (scenario == "refused" ? 0 : 2))
            if scenario == "success" {
                #expect(run.status == "completed" && source.cursor != nil && source.lastIntakeAt != nil)
                // Gmail results carry no link; one is built from the thread ID when the model gives none.
                #expect(events.map(\.url) == ["https://mail.example.com/m1", "https://mail.google.com/mail/u/0/#all/t2"])
            } else {
                #expect(run.status == "failed" && source.cursor == nil && source.lastIntakeAt == nil)
            }
            // A failed Source waits for its interval instead of running again on the next tick.
            await fixture.service.drainAlwaysOn()
            #expect(await fixture.service.intakeTask == nil && fixture.pi.launches.all.count { $0.profile == .intake } == 1)
        }

        @Test(arguments: ["before", "during"])
        func aReusedMCPNameCannotRebindAnExistingSource(change: String) async throws {
            let fixture = try fixture(
                calls: [("eventRecord", Self.twoItems)], ending: [TestPiTransport.assistantEnd("Recorded."), TestPiTransport.settled()],
                registryChange: change
            )
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            await drain(fixture)
            let (source, runs, events) = try await saved(fixture)
            #expect(source.cursor == nil && source.lastIntakeAt == nil && events.isEmpty)
            #expect(runs.map(\.status) == ["interrupted"])
            #expect(fixture.pi.launches.all.count == (change == "before" ? 0 : 1))
        }

        @Test(arguments: [false, true])
        func anEmptyReadAndAnAnswerWithoutReadingHaveDifferentOutcomes(read: Bool) async throws {
            let fixture = try fixture(
                calls: [("eventRecord", .object(["items": .array([])]))],
                ending: [TestPiTransport.assistantEnd("No messages."), TestPiTransport.settled()], readSucceeded: read
            )
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            await drain(fixture)
            let (source, runs, _) = try await saved(fixture)
            #expect((source.cursor != nil) == read)
            #expect(runs.map(\.status) == [read ? "completed" : "failed"])
        }

        @Test func sourceReadErrorsNeverUseTheMismatchSkipEscape() async throws {
            let fixture = try fixture(
                calls: [("intakeReadFailed", .object([:])), ("eventRecord", Self.twoItems)],
                ending: [TestPiTransport.assistantEnd("Could not read another page."), TestPiTransport.settled()]
            )
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let start = Date.now
            for attempt in 0 ... PiChatService.intakeMismatchLimit {
                await drain(fixture, at: start.addingTimeInterval(Double(attempt) * 1200))
            }
            let (source, runs, events) = try await saved(fixture)
            #expect(runs.count == PiChatService.intakeMismatchLimit + 1 && runs.allSatisfy { $0.status == "failed" })
            #expect(source.cursor == nil && source.lastIntakeAt == nil && source.gapDetectedAt == nil)
            #expect(events.count == 2)
        }

        private func page(_ cursor: String = "", next: String = "", key: String = "query", more: Bool = false) -> (String, JSONValue) {
            ("intakeSeen", .object(["ids": .array([]), "pages": .array([.object([
                "requestKey": .string("\(key)|\(cursor)"),
                "nextRequestKey": .string(next.isEmpty ? "" : "\(key)|\(next)"),
                "root": .bool(cursor.isEmpty), "hasMore": .bool(more),
            ])])]))
        }

        @Test(arguments: ["open", "complete", "unrelated", "missingCursor", "cycle", "orphan", "outOfOrder", "repeatedRoot"])
        func everyObservedQueryMustReachItsLastPage(scenario: String) async throws {
            var pages = [page(next: "p2", more: true)]
            switch scenario {
            case "complete": pages.append(page("p2"))
            case "unrelated": pages.append(page(key: "other query"))
            case "missingCursor": pages = [page(more: true)]
            case "cycle": pages.append(page("p2", next: "p2", more: true))
            case "orphan": pages = [page("p2")]
            case "outOfOrder": pages.insert(page("p2"), at: 0)
            case "repeatedRoot": pages.append(page())
            default: break
            }
            let fixture = try fixture(
                calls: pages + [("eventRecord", Self.twoItems)],
                ending: [TestPiTransport.assistantEnd("Recorded every item on this page."), TestPiTransport.settled()]
            )
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let complete = ["complete", "outOfOrder"].contains(scenario)
            let start = Date.now
            // Incomplete pagination must never use the record-mismatch escape after repeated attempts.
            for attempt in 0 ... (complete ? 0 : PiChatService.intakeMismatchLimit) {
                await drain(fixture, at: start.addingTimeInterval(Double(attempt) * 1200))
            }
            let (source, runs, events) = try await saved(fixture)
            #expect((source.cursor != nil) == complete && source.gapDetectedAt == nil)
            #expect(runs.count == (complete ? 1 : PiChatService.intakeMismatchLimit + 1))
            #expect(runs
                .allSatisfy {
                    $0.status == (complete ? "completed" : "failed") && (complete || $0.report.contains("The Source read did not complete"))
                })
            #expect(events.count == 2)
        }

        @Test(arguments: [false, true])
        func distinctRequestsCompleteIndependently(missingSmallPage: Bool) async throws {
            // Keys represent complete opaque requests, including page size and any other search argument.
            var pages = [
                page(next: "p2", key: "same-query-size-1", more: true),
                page(key: "same-query-size-100"),
                page(key: "same-query-size-100-another-filter"),
            ]
            if !missingSmallPage { pages.append(page("p2", key: "same-query-size-1")) }
            let fixture = try fixture(
                calls: pages + [("eventRecord", Self.twoItems)],
                ending: [TestPiTransport.assistantEnd("Every returned item recorded."), TestPiTransport.settled()]
            )
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            await drain(fixture)
            let (source, runs, events) = try await saved(fixture)
            #expect((source.cursor == nil) == missingSmallPage && source.gapDetectedAt == nil)
            #expect(runs.map(\.status) == [missingSmallPage ? "failed" : "completed"])
            #expect(events.count == 2)
        }

        @Test(arguments: ["queryMismatch", "cursorMismatch", "conflictingNext", "independent", "exact"])
        func requestIdentityPreservesUnicodeBytes(scenario: String) async throws {
            let composed = "caf\u{E9}"
            let decomposed = "cafe\u{301}"
            #expect(composed == decomposed && Data(composed.utf8) != Data(decomposed.utf8))
            var pages = [page(next: "p2", key: composed), page("p2", key: composed)]
            switch scenario {
            case "queryMismatch": pages = [page(next: "p2", key: composed), page("p2", key: decomposed)]
            case "cursorMismatch": pages = [page(next: composed), page(decomposed)]
            case "conflictingNext": pages = [page(next: composed), page(next: decomposed), page(decomposed)]
            case "independent":
                pages = [
                    page(next: "p2", key: composed), page(next: "p3", key: decomposed),
                    page("p2", key: composed), page("p3", key: decomposed),
                ]
            default: break
            }
            let fixture = try fixture(
                calls: pages + [("eventRecord", Self.twoItems)],
                ending: [TestPiTransport.assistantEnd("Recorded."), TestPiTransport.settled()]
            )
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            await drain(fixture)
            let (source, runs, _) = try await saved(fixture)
            let complete = ["independent", "exact"].contains(scenario)
            #expect((source.cursor != nil) == complete && source.gapDetectedAt == nil)
            #expect(runs.map(\.status) == [complete ? "completed" : "failed"])
        }

        @Test func aLateIntakeCompletionCannotRestoreDeletedAccountHistory() async throws {
            let fixture = try fixture(calls: [], ending: [])
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            await fixture.service.drainAlwaysOn()
            let transport = await fixture.transports.transport(at: 0)
            _ = await transport.command { $0["type"] == .string("extension_ui_response") && $0["id"] == .string("r1") }
            let (source, runs, _) = try await saved(fixture)
            #expect(runs.map(\.status) == ["running"])
            let accountID = try #require(UUID(uuidString: source.accountID))
            try await MeetingRepository(dbQueue: fixture.db).deleteDahliaAccountConnection(id: accountID)
            await transport.emit(TestPiTransport.assistantEnd("Done."))
            await transport.emit(TestPiTransport.settled())
            await fixture.service.intakeTask?.value
            #expect(try await fixture.db.read { try AgentSystemRunRecord.fetchCount($0) } == 0)
            #expect(try await fixture.db.read { try AgentSourceRecord.fetchCount($0) } == 0)
        }

        /// Listed items left unrecorded, or a batch Dahlia refused, hold the position; the limit keeps intake from stalling.
        @Test(arguments: ["listed", "refused"])
        func incompleteRunsHoldThePositionUntilTheLimit(scenario: String) async throws {
            let listed = JSONValue.object(["ids": .array(["m1", "m2", "m3"].map(JSONValue.string))])
            let refused = JSONValue.object(["items": .array([.object(["subject": .string("no id")])])])
            let fixture = try fixture(
                calls: scenario == "listed" ? [("intakeSeen", listed), ("eventRecord", Self.twoItems)] : [("eventRecord", refused)],
                ending: [TestPiTransport.assistantEnd("Recorded."), TestPiTransport.settled()]
            )
            defer { try? FileManager.default.removeItem(at: fixture.pi.rootURL) }
            let start = Date.now

            for run in 0 ..< PiChatService.intakeMismatchLimit - 1 {
                await drain(fixture, at: start.addingTimeInterval(Double(run) * 1200))
                let (source, runs, _) = try await saved(fixture)
                #expect(source.cursor == nil && source.gapDetectedAt == nil && runs.last?.status == "failed")
            }
            await drain(fixture, at: start.addingTimeInterval(Double(PiChatService.intakeMismatchLimit) * 1200))

            let (source, runs, _) = try await saved(fixture)
            #expect(runs.count == PiChatService.intakeMismatchLimit && runs.last?.status == "completed")
            #expect(source.cursor != nil && source.gapDetectedAt != nil)
        }
    }
#endif
