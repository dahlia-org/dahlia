#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct AgentInboxServiceTests {
        private let account = "local"

        private func inbox(sieve: String = "candidate", allowedSenders: [String] = []) throws -> (AgentInboxService, String) {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let source = UUID.v7().uuidString
            try queue.write { db in
                try AgentSourceRecord(
                    id: source, accountID: account, name: "Mail", server: "gmail", instructions: "Unread mail", intervalMinutes: 15,
                    sieve: sieve, allowedSenders: String(decoding: JSONEncoder().encode(allowedSenders), as: UTF8.self), cursor: nil,
                    enabled: true, gapDetectedAt: nil, lastIntakeAt: nil, createdAt: .now, updatedAt: .now, connectionID: "gmail"
                ).insert(db)
            }
            return (AgentInboxService(dbQueue: queue), source)
        }

        private func item(_ id: String, topic: String = "thread-1", direct: Bool = true) -> AgentInboxService.IntakeItem {
            .init(
                externalID: id,
                topicKey: topic,
                sender: "a@example.com",
                subject: "Hello",
                excerpt: "…",
                url: "https://mail.example.com/\(id)",
                ref: .object(["messageId": .string(id)]),
                direct: direct
            )
        }

        private func eventIDs(_ service: AgentInboxService, status: String) throws -> [String] {
            try service.dbQueue.read {
                try String.fetchAll($0, sql: "SELECT id FROM agent_event_inbox WHERE status=? ORDER BY createdAt, id", arguments: [status])
            }
        }

        /// One Router-created task owning `thread-1`, with its first event already delivered and processed.
        private func openTask(_ service: AgentInboxService, source: String) throws -> String {
            try service.record([item("m1")], caller: .intake(sourceID: source), account: account)
            let task = try service.createTask(
                title: "Reply", instructions: "Answer", eventIDs: eventIDs(service, status: "unassigned"), caller: .router, account: account
            ).id
            let delivered = try service.deliver(taskID: task, account: account)
            try service.markProcessed(delivered.map(\.id), caller: .worker(taskID: task), account: account)
            return task
        }

        @Test(arguments: ["instructions", "disabled", "deleted"])
        func obsoleteIntakeCannotPublishOrAdvanceItsSource(change: String) throws {
            let (service, id) = try inbox()
            var source = try #require(try service.sources(account: account).first)
            if change == "deleted" {
                try service.deleteSource(id: id, account: account)
            } else {
                source.instructions = "Read a different range"
                source.enabled = change != "disabled"
                try service.saveSource(source)
            }
            #expect(throws: AgentInboxService.Failure.self) {
                try service.record([item("old")], caller: .intake(sourceID: id, revision: 1), account: account)
            }
            #expect(throws: AgentInboxService.Failure.self) {
                try service.commitIntake(sourceID: id, revision: 1, account: account, cursor: "stale", seen: [])
            }
            #expect(throws: AgentInboxService.Failure.self) { try service.markGap(sourceID: id, revision: 1, account: account) }
            #expect(try service.recentEvents(account: account).isEmpty)
            #expect(try service.sources(account: account).first?.cursor == nil)
            if change == "instructions" {
                let current = try #require(try service.sources(account: account).first)
                #expect(current.revision == 2)
                try service.record([item("fresh")], caller: .intake(sourceID: id, revision: current.revision), account: account)
                #expect(try service.commitIntake(sourceID: id, revision: current.revision, account: account, cursor: "fresh", seen: ["fresh"]))
            }
        }

        @Test func aSourceCannotReinterpretTheOriginOfItsExistingEvents() throws {
            let (service, id) = try inbox()
            try service.record([item("gmail-1")], caller: .intake(sourceID: id), account: account)
            var changed = try #require(try service.sources(account: account).first)
            changed.server = "slack"
            #expect(throws: AgentInboxService.Failure.self) { try service.saveSource(changed) }
            changed.server = "gmail"
            changed.connectionID = "replacement-registration"
            #expect(throws: AgentInboxService.Failure.self) { try service.saveSource(changed) }
            #expect(try service.sources(account: account).first?.server == "gmail")
            #expect(try service.sources(account: account).first?.revision == 1)
            let task = try service.createTask(
                title: "Read", instructions: "Read", eventIDs: eventIDs(service, status: "unassigned"), caller: .router, account: account
            )
            #expect(task.servers == #"["gmail"]"#)
            let event = try #require(try service.deliver(taskID: task.id, account: account).first)
            #expect(event.externalID == "gmail-1" && event.ref == #"{"messageId":"gmail-1"}"#)
        }

        @Test(arguments: ["done", "dismissed"], [true, false])
        func endingATaskReturnsUndeliveredFollowUpsToTheRouter(status: String, workerRunning: Bool) throws {
            let (service, id) = try inbox()
            try service.record([item("m1")], caller: .intake(sourceID: id), account: account)
            let task = try service.createTask(
                title: "Read", instructions: "Read", eventIDs: eventIDs(service, status: "unassigned"), caller: .router, account: account
            )
            let delivered = try service.deliver(taskID: task.id, account: account)
            let runID = UUID.v7()
            var run = try ChatRunRecord(
                id: runID, threadID: #require(task.threadID), rootRunID: runID, status: workerRunning ? "running" : "queued",
                input: "Read", effort: "medium", approvalMethod: "ask", createdAt: .now
            )
            run.origin = "task"
            let saved = run
            try service.dbQueue.write { try saved.insert($0) }
            try service.record([item("m2")], caller: .intake(sourceID: id), account: account)
            _ = try service.route(account: account)
            let followUp = try #require(try eventIDs(service, status: "assigned").first)
            try service.finishTask(taskID: task.id, status: status, caller: .router, account: account)
            try service.settleDelivery(taskID: task.id, account: account, succeeded: true)
            try service.recover()
            let returned = delivered.map(\.id) + [followUp]
            #expect(try eventIDs(service, status: "processed").isEmpty)
            #expect(try service.routerInput(account: account).events.map(\.id) == returned)
            #expect(try service.routerInput(account: account).events.allSatisfy { $0.taskID == nil })
            #expect(try service.route(account: account).routerNeeded)
            #expect(try service.idleTasks([task.id], account: account).isEmpty)
            if !workerRunning { #expect(try ChatThreadStore(dbQueue: service.dbQueue).run(id: runID)?.status == "interrupted") }
            let next = try service.createTask(title: "Follow-up", instructions: "Read", eventIDs: returned, caller: .router, account: account)
            #expect(try service.deliver(taskID: next.id, account: account).map(\.id) == returned)
        }

        @Test func explicitAssignmentGrantsEachNewSourceServer() throws {
            let (service, first) = try inbox()
            let taskID = try openTask(service, source: first)
            var second = try #require(try service.sources(account: account).first)
            second.id = UUID.v7().uuidString
            second.server = "slack"
            second.connectionID = "slack"
            try service.saveSource(second)
            try service.record([item("slack-1")], caller: .intake(sourceID: second.id), account: account)
            let ids = try eventIDs(service, status: "unassigned")
            try service.assign(eventIDs: ids, taskID: taskID, caller: .router, account: account)
            #expect(try service.task(taskID, account: account)?.servers == #"["gmail","slack"]"#)
            try service.assign(eventIDs: ids, taskID: taskID, caller: .router, account: account)
            #expect(try service.task(taskID, account: account)?.servers == #"["gmail","slack"]"#)
        }

        @Test(arguments: ["active", "queued", "bulk", "accountSwitch"])
        func workerTerminationSettlesCancellationButPreservesAccountSwitch(mode: String) throws {
            let (service, source) = try inbox()
            try service.record([item("m1")], caller: .intake(sourceID: source), account: account)
            let task = try service.createTask(
                title: "Work", instructions: "Read", eventIDs: eventIDs(service, status: "unassigned"), caller: .router, account: account
            )
            _ = try service.deliver(taskID: task.id, account: account)
            try service.setTimer(note: "Come back", dueAt: .now.addingTimeInterval(60), caller: .worker(taskID: task.id), account: account)
            let id = UUID.v7()
            var run = try ChatRunRecord(
                id: id, threadID: #require(task.threadID), rootRunID: id, status: mode == "active" ? "running" : "queued",
                input: "Work", effort: "medium", approvalMethod: "ask", createdAt: .now
            )
            run.origin = "task"
            let saved = run
            try service.dbQueue.write { try saved.insert($0) }
            let store = ChatThreadStore(dbQueue: service.dbQueue)
            switch mode {
            case "active": try store.markStoppedByUser(id)
            case "queued": try store.interruptQueuedRun(id)
            default: try store.interruptQueuedRuns(accountID: account, preservingSchedules: mode == "accountSwitch")
            }
            let preserved = mode == "accountSwitch"
            #expect(try service.task(task.id, account: account)?.status == (preserved ? "active" : "dismissed"))
            #expect(try eventIDs(service, status: preserved ? "delivered" : "processed").count == 1)
            #expect(try store.run(id: id)?.status == (mode == "active" ? "running" : preserved ? "queued" : "interrupted"))
            #expect(try service.route(account: account, now: .now.addingTimeInterval(3600)).tasksToDeliver.isEmpty)
            if !preserved {
                try service.fireTimers(account: account, now: .now.addingTimeInterval(3600))
                #expect(try service.routerInput(account: account).events.isEmpty)
            }
        }

        // MARK: intake

        @Test func intakeKeepsOneRowPerItemAndSievesBeforeTheRouter() throws {
            let (service, source) = try inbox(sieve: "explicit", allowedSenders: ["a@example.com"])
            var stranger = item("m3")
            stranger.sender = "spam@example.com"
            let first = try service.record([item("m1"), item("m2", direct: false), stranger], caller: .intake(sourceID: source), account: account)
            let again = try service.record([item("m1")], caller: .intake(sourceID: source), account: account)

            #expect(first == ["m1": "unassigned", "m2": "ignored", "m3": "ignored"])
            #expect(again == ["m1": "duplicate"])
            #expect(try service.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM agent_event_inbox") } == 3)
            let event = try #require(try service.dbQueue.read {
                try AgentEventRecord.fetchOne($0, sql: "SELECT * FROM agent_event_inbox WHERE externalID='m1'")
            })
            #expect(event.url == "https://mail.example.com/m1" && event.ref == #"{"messageId":"m1"}"#)
            #expect(try service.route(account: account) == .init(tasksToDeliver: [], routerNeeded: true))
            #expect(try eventIDs(service, status: "unassigned").count == 1)
        }

        @Test func readPositionMovesOnlyWhenEveryReturnedItemHasARow() throws {
            let (service, source) = try inbox()
            try service.record([item("m1")], caller: .intake(sourceID: source), account: account)

            #expect(try !service.commitIntake(sourceID: source, account: account, cursor: "page-2", seen: ["m1", "m2"]))
            #expect(try service.dbQueue.read { try AgentSourceRecord.fetchOne($0, key: source)?.cursor } == nil)
            try service.record([item("m2", direct: false)], caller: .intake(sourceID: source), account: account)
            #expect(try service.commitIntake(sourceID: source, account: account, cursor: "page-2", seen: ["m1", "m2"]))
            #expect(try service.dbQueue.read { try AgentSourceRecord.fetchOne($0, key: source)?.cursor } == "page-2")
        }

        @Test func recordToolArgumentsAreBoundedAndOnlyWebLinksAreKept() throws {
            let long = String(repeating: "あ", count: 2000)
            let items = try AgentInboxService.items(from: .object(["items": .array([
                .object([
                    "external_id": .string(" m1 "), "excerpt": .string(long), "subject": .string(long), "url": .string("javascript:alert(1)"),
                    "occurred_at": .string("2026-11-19T09:00:00Z"), "direct": .bool(true), "ref": .object(["id": .string("m1")]),
                ]),
                .object(["external_id": .string("m2"), "url": .string("https://mail.example.com/m2"), "ref": .null]),
            ])]))

            #expect(items.map(\.externalID) == ["m1", "m2"])
            #expect(items[0].excerpt.count == AgentInboxService.excerptLimit && items[0].subject?.count == AgentInboxService.fieldLimit)
            #expect(items[0].url == nil && items[1].url == "https://mail.example.com/m2")
            #expect(items[0].occurredAt == Date(timeIntervalSince1970: 1_795_078_800) && items[0].direct && !items[1].direct)
            #expect(items[0].ref == .object(["id": .string("m1")]) && items[1].ref == nil)
            for bad: JSONValue in [
                .object([:]), .object(["items": .array([.object(["subject": .string("no id")])])]),
                .object(["items": .array([.object(["external_id": .string("m3"), "ref": .string(String(repeating: "x", count: 5000))])])]),
            ] {
                #expect(throws: AgentInboxService.Failure.self) { try AgentInboxService.items(from: bad) }
            }
        }

        @Test func gmailLinksKeepOnlyThreadIDCharacters() {
            #expect(AgentInboxService.gmailURL(threadID: "18c2f\"/../x") == "https://mail.google.com/mail/u/0/#all/18c2fx")
            #expect(AgentInboxService.gmailURL(threadID: "../") == nil)
        }

        @Test func sourcesAreDueOnceTheirIntervalHasPassed() throws {
            let (service, source) = try inbox()
            let now = Date(timeIntervalSince1970: 100_000)
            #expect(try service.dueSources(account: account, now: now).map(\.id) == [source])
            #expect(try service.commitIntake(sourceID: source, account: account, cursor: "c", seen: [], now: now))
            #expect(try service.dueSources(account: account, now: now.addingTimeInterval(14 * 60)).isEmpty)
            #expect(try service.dueSources(account: account, now: now.addingTimeInterval(15 * 60)).map(\.id) == [source])
            var disabled = try #require(try service.sources(account: account).first)
            disabled.enabled = false
            try service.saveSource(disabled)
            #expect(try service.dueSources(account: account, now: now.addingTimeInterval(3600)).isEmpty)
            disabled.intervalMinutes = 1
            #expect(throws: AgentInboxService.Failure.self) { try service.saveSource(disabled) }
        }

        @Test func intakeProfileReadsOnlyItsSourceAndRecords() {
            #expect(PiExecutionProfile.intake.allows("event_record"))
            #expect(PiExecutionProfile.intake.allows("mcp__gmail__search_messages", readOnly: true))
            #expect(!PiExecutionProfile.intake.allows("mcp__gmail__send_message"))
            #expect(!PiExecutionProfile.intake.allows("mcp__dahlia__get_meeting", readOnly: true))
            #expect(!PiExecutionProfile.intake.allows("read") && PiExecutionProfile.intake.fileTools.isEmpty)
        }

        @Test func onlyAnIntakeRunRecordsItems() throws {
            let (service, source) = try inbox()
            #expect(throws: AgentInboxService.Failure.self) {
                try service.record([item("m1")], caller: .worker(taskID: source), account: account)
            }
        }

        // MARK: routing

        @Test func onlyTheRouterAssignsEventsAndOpensOrFinishesTasks() throws {
            let (service, source) = try inbox()
            try service.record([item("m1")], caller: .intake(sourceID: source), account: account)
            let events = try eventIDs(service, status: "unassigned")
            for caller in [AgentInboxService.Caller.worker(taskID: "t"), .intake(sourceID: source)] {
                #expect(throws: AgentInboxService.Failure.self) {
                    try service.createTask(title: "x", instructions: "x", eventIDs: events, caller: caller, account: account)
                }
                #expect(throws: AgentInboxService.Failure.self) { try service.assign(eventIDs: events, taskID: "t", caller: caller, account: account)
                }
                #expect(throws: AgentInboxService.Failure.self) { try service.close(eventIDs: events, caller: caller, account: account) }
                #expect(throws: AgentInboxService.Failure.self) {
                    try service.finishTask(taskID: "t", status: "done", caller: caller, account: account)
                }
            }
            #expect(try eventIDs(service, status: "unassigned") == events)
        }

        @Test func followUpsOfAnOwnedTopicSkipTheRouterButResultsDoNot() throws {
            let (service, source) = try inbox()
            let task = try openTask(service, source: source)
            try service.record([item("m2")], caller: .intake(sourceID: source), account: account)
            try service.addResult(summary: "Replied", caller: .worker(taskID: task), account: account)

            #expect(try service.route(account: account) == .init(tasksToDeliver: [task], routerNeeded: true))
            let delivered = try service.deliver(taskID: task, account: account)
            #expect(delivered.map(\.externalID) == ["m2"])
            let pending = try service.dbQueue.read {
                try AgentEventRecord.fetchAll($0, sql: "SELECT * FROM agent_event_inbox WHERE status='unassigned'")
            }
            #expect(pending.map(\.kind) == ["result"])
        }

        @Test func returnedEventsAndFollowUpsOfFinishedTasksGoBackToTheRouter() throws {
            let (service, source) = try inbox()
            let task = try openTask(service, source: source)
            try service.record([item("m2")], caller: .intake(sourceID: source), account: account)
            _ = try service.route(account: account)
            let delivered = try service.deliver(taskID: task, account: account)
            try service.returnEvents(delivered.map(\.id), caller: .worker(taskID: task), account: account)
            try service.record([item("m3")], caller: .intake(sourceID: source), account: account)

            #expect(try service.route(account: account) == .init(tasksToDeliver: [], routerNeeded: true))
            #expect(try eventIDs(service, status: "unassigned").count == 2)

            let other = try openTask(service, source: source)
            try service.finishTask(taskID: other, status: "done", caller: .router, account: account)
            try service.record([item("m9")], caller: .intake(sourceID: source), account: account)
            #expect(try service.route(account: account).tasksToDeliver.isEmpty)
        }

        @Test func eventsAWorkerNeverSettledAreDeliveredAgainAfterARestart() throws {
            let (service, source) = try inbox()
            let task = try openTask(service, source: source)
            try service.record([item("m2")], caller: .intake(sourceID: source), account: account)
            _ = try service.route(account: account)
            // The Worker received the follow-up and the app quit before its run settled.
            _ = try service.deliver(taskID: task, account: account)

            try service.recover()

            #expect(try service.route(account: account).tasksToDeliver == [task])
            #expect(try service.deliver(taskID: task, account: account).map(\.externalID) == ["m2"])
        }

        @Test func timersWakeTheirActiveTaskAndOtherwiseTheRouter() throws {
            let (service, source) = try inbox()
            let task = try openTask(service, source: source)
            try service.setTimer(note: "Reply came?", dueAt: Date(timeIntervalSince1970: 10), caller: .worker(taskID: task), account: account)
            try service.fireTimers(account: account, now: Date(timeIntervalSince1970: 5))
            #expect(try service.route(account: account) == .init(tasksToDeliver: [], routerNeeded: false))

            try service.fireTimers(account: account, now: Date(timeIntervalSince1970: 20))
            try service.fireTimers(account: account, now: Date(timeIntervalSince1970: 30))
            #expect(try service.route(account: account) == .init(tasksToDeliver: [task], routerNeeded: false))
            #expect(try service.deliver(taskID: task, account: account).map(\.kind) == ["timer"])
        }

        // MARK: writes

        @Test func aWriteNobodyApprovedNeverRuns() throws {
            let (service, source) = try inbox()
            let task = try openTask(service, source: source)
            let worker = AgentInboxService.Caller.worker(taskID: task)
            let (action, authorization) = try service.propose(
                server: "gmail", tool: "send", arguments: .object(["to": .string("a@example.com")]), principal: "me", caller: worker, account: account
            )
            #expect(authorization == .pending)
            #expect(throws: AgentInboxService.Failure.self) {
                try service.claimExecution(actionID: action.id, revision: 1, principal: "me", caller: worker, account: account)
            }
            // A restart keeps the write waiting for the user.
            try service.recover()
            #expect(try service.dbQueue.read { try AgentActionRecord.fetchOne($0, key: action.id)?.status } == "pending")
        }

        @Test func anApprovedWriteRunsOnceWithTheArgumentsTheUserSaw() throws {
            let (service, source) = try inbox()
            let task = try openTask(service, source: source)
            let worker = AgentInboxService.Caller.worker(taskID: task)
            let arguments = JSONValue.object(["to": .string("a@example.com"), "body": .string("了解しました")])
            let (action, _) = try service.propose(
                server: "gmail",
                tool: "send",
                arguments: arguments,
                principal: "me",
                caller: worker,
                account: account
            )

            try service.decide(.approve(revision: 1), actionID: action.id, account: account)
            #expect(try service.route(account: account).tasksToDeliver == [task])
            let claimed = try service.claimExecution(actionID: action.id, revision: 1, principal: "me", caller: worker, account: account)

            #expect(try JSONDecoder().decode(JSONValue.self, from: Data(claimed.arguments.utf8)) == arguments)
            #expect(throws: AgentInboxService.Failure.self) {
                try service.claimExecution(actionID: action.id, revision: 1, principal: "me", caller: worker, account: account)
            }
            try service.finishExecution(actionID: action.id, result: .object([:]), succeeded: true, caller: worker, account: account)
            #expect(try service.dbQueue.read { try AgentActionRecord.fetchOne($0, key: action.id)?.status } == "succeeded")
        }

        @Test func aWriteThatStartedBeforeARestartIsUnknownAndNotSentAgain() throws {
            let (service, source) = try inbox()
            let task = try openTask(service, source: source)
            let worker = AgentInboxService.Caller.worker(taskID: task)
            _ = try service.setPolicy(server: "gmail", tool: "label", conditions: [:], level: 4, account: account)
            let (action, authorization) = try service.propose(
                server: "gmail", tool: "label", arguments: .object(["messageId": .string("m1")]), principal: "me", caller: worker, account: account
            )
            #expect(authorization == .allowed)
            _ = try service.claimExecution(actionID: action.id, revision: 1, principal: "me", caller: worker, account: account)

            try service.recover()

            #expect(try service.dbQueue.read { try AgentActionRecord.fetchOne($0, key: action.id)?.status } == "unknown")
            #expect(throws: AgentInboxService.Failure.self) {
                try service.claimExecution(actionID: action.id, revision: 1, principal: "me", caller: worker, account: account)
            }
        }

        @Test func approvalIsVoidOnceTheRevisionPrincipalPolicyOrSwitchChanges() throws {
            let (service, source) = try inbox()
            let task = try openTask(service, source: source)
            let worker = AgentInboxService.Caller.worker(taskID: task)
            func propose() throws -> String {
                try service.propose(
                    server: "gmail", tool: "label", arguments: .object(["messageId": .string("m1")]), principal: "me", caller: worker,
                    account: account
                ).action.id
            }

            // An approval of a revision the user no longer sees changes nothing.
            let stale = try propose()
            try service.decide(.edit(revision: 1, arguments: .object(["messageId": .string("m2")])), actionID: stale, account: account)
            try service.decide(.approve(revision: 1), actionID: stale, account: account, now: .now.addingTimeInterval(1))
            _ = try service.route(account: account)
            let edited = try #require(try service.dbQueue.read { try AgentActionRecord.fetchOne($0, key: stale) })
            #expect(edited.revision == 2 && edited.approvedRevision == 2 && edited.arguments == #"{"messageId":"m2"}"#)
            #expect(throws: AgentInboxService.Failure.self) {
                try service.claimExecution(actionID: stale, revision: 1, principal: "me", caller: worker, account: account)
            }

            // The account signed in to the server changed.
            #expect(throws: AgentInboxService.Failure.self) {
                try service.claimExecution(actionID: stale, revision: 2, principal: "someone-else", caller: worker, account: account)
            }

            // The policy that allowed it was revoked before it ran.
            let policy = try service.setPolicy(server: "gmail", tool: "label", conditions: [:], level: 4, account: account)
            let allowed = try propose()
            try service.revokePolicy(id: policy.id, account: account)
            #expect(throws: AgentInboxService.Failure.self) {
                try service.claimExecution(actionID: allowed, revision: 1, principal: "me", caller: worker, account: account)
            }

            // Everything is paused.
            try service.setPaused(true, account: account)
            #expect(throws: AgentInboxService.Failure.self) {
                try service.claimExecution(actionID: stale, revision: 2, principal: "me", caller: worker, account: account)
            }
            try service.setPaused(false, account: account)
            _ = try service.claimExecution(actionID: stale, revision: 2, principal: "me", caller: worker, account: account)
        }

        @Test func policiesNeverAutoSendFreeTextAndRestrictiveOnesWin() throws {
            let (service, source) = try inbox()
            let task = try openTask(service, source: source)
            let worker = AgentInboxService.Caller.worker(taskID: task)
            _ = try service.setPolicy(server: "slack", tool: "post", conditions: ["channel": .string("C1")], level: 4, account: account)
            func authorize(_ arguments: [String: JSONValue], tool: String = "post") throws -> AgentInboxService.Authorization {
                try service.propose(server: "slack", tool: tool, arguments: .object(arguments), principal: "me", caller: worker, account: account)
                    .authorization
            }

            #expect(try authorize(["channel": .string("C1"), "emoji": .string("white_check_mark")]) == .allowed)
            #expect(try authorize(["channel": .string("C1"), "text": .string("Thanks for the update")]) == .pending)
            #expect(try authorize(["channel": .string("C1"), "text": .string("了解しました")]) == .pending)
            #expect(try authorize(["channel": .string("C2"), "emoji": .string("ok")]) == .pending)

            _ = try service.setPolicy(server: "slack", tool: "post", conditions: [:], level: 2, account: account)
            #expect(try authorize(["channel": .string("C1"), "emoji": .string("ok")]) == .denied)
        }

        @Test func finishingATaskDropsTheWritesItHadNotRun() throws {
            let (service, source) = try inbox()
            let task = try openTask(service, source: source)
            let worker = AgentInboxService.Caller.worker(taskID: task)
            let (action, _) = try service.propose(
                server: "gmail",
                tool: "send",
                arguments: .object([:]),
                principal: "me",
                caller: worker,
                account: account
            )
            try service.finishTask(taskID: task, status: "dismissed", caller: .router, account: account)
            try service.decide(.approve(revision: 1), actionID: action.id, account: account)
            _ = try service.route(account: account)

            #expect(try service.dbQueue.read { try AgentActionRecord.fetchOne($0, key: action.id)?.status } == "rejected")
            #expect(throws: AgentInboxService.Failure.self) {
                try service.propose(server: "gmail", tool: "send", arguments: .object([:]), principal: "me", caller: worker, account: account)
            }
        }

        // MARK: Dahlia Bot

        @Test func requestsGoToTheRouterAndTasksReadTheirSourcesServer() throws {
            let (service, source) = try inbox()
            try service.request("明日の会議の資料を作って", account: account)
            try service.record([item("m1")], caller: .intake(sourceID: source), account: account)
            #expect(try service.route(account: account) == .init(tasksToDeliver: [], routerNeeded: true))
            let events = try service.routerInput(account: account).events
            #expect(Set(events.map(\.kind)) == ["request", "external"])
            #expect(throws: AgentInboxService.Failure.self) { try service.request("  ", account: account) }

            let task = try service.createTask(
                title: "Prepare", instructions: "Notes", eventIDs: events.map(\.id), servers: ["drive"], caller: .router, account: account
            )
            #expect(task.servers == #"["drive","gmail"]"#)
        }

        @Test func onlyTheRouterMakesItemsAndRecentDismissalsBlockASuggestion() throws {
            let (service, _) = try inbox()
            #expect(throws: AgentInboxService.Failure.self) {
                try service.createItem(kind: "report", title: "Done", caller: .worker(taskID: "t"), account: account)
            }
            #expect(throws: AgentInboxService.Failure.self) {
                try service.createItem(kind: "approval", title: "Send?", caller: .router, account: account)
            }
            let suggestion = try service.createItem(kind: "suggestion", title: "Reply to Dana", caller: .router, account: account)
            #expect(try service.dismiss(itemID: suggestion.id, revision: 1, account: account))
            #expect(throws: AgentInboxService.Failure.self) {
                try service.createItem(kind: "suggestion", title: "Reply to Dana", caller: .router, account: account)
            }
            // A suggestion nobody acted on leaves the inbox after three days.
            let start = Date(timeIntervalSince1970: 1_000_000)
            try service.createItem(kind: "suggestion", title: "Follow up", caller: .router, account: account, now: start)
            _ = try service.route(account: account, now: start.addingTimeInterval(AgentInboxService.suggestionLifetime + 1))
            #expect(try service.items(account: account).isEmpty)
            // No answer event comes from a dismissed suggestion or a seen report.
            let report = try service.createItem(kind: "report", title: "Notes ready", caller: .router, account: account)
            #expect(try service.dismiss(itemID: report.id, revision: 1, account: account))
            #expect(try service.routerInput(account: account).events.isEmpty)
        }

        @Test func anAnswerReachesTheAskingWorkerOnceAndAStaleOneChangesNothing() throws {
            let (service, source) = try inbox()
            let task = try openTask(service, source: source)
            let question = try service.createItem(
                kind: "question", title: "Which deck?", options: ["Q3", "Q4"], recommended: 1, taskID: task, caller: .router, account: account
            )
            #expect(question.recommended == 1)

            #expect(try !service.answer(itemID: question.id, revision: 2, answer: "Q3", account: account))
            #expect(try service.answer(itemID: question.id, revision: 1, answer: "Q4", account: account))
            #expect(try !service.answer(itemID: question.id, revision: 1, answer: "Q3", account: account))
            #expect(try service.items(account: account).isEmpty)

            #expect(try service.route(account: account) == .init(tasksToDeliver: [task], routerNeeded: false))
            let delivered = try service.deliver(taskID: task, account: account)
            #expect(delivered.map(\.kind) == ["answer"] && delivered.map(\.excerpt) == ["Q4"])
            // Delivered and not yet settled when the app quit: it arrives again after a restart.
            try service.recover()
            #expect(try service.route(account: account).tasksToDeliver == [task])
        }

        @Test func answersToAFinishedTaskAndDismissedQuestionsStillReachSomeone() throws {
            let (service, source) = try inbox()
            let task = try openTask(service, source: source)
            let question = try service.createItem(kind: "question", title: "Send now?", taskID: task, caller: .router, account: account)
            try service.finishTask(taskID: task, status: "done", caller: .router, account: account)
            #expect(try service.dismiss(itemID: question.id, revision: 1, account: account))

            #expect(try service.route(account: account) == .init(tasksToDeliver: [], routerNeeded: true))
            let event = try #require(try service.routerInput(account: account).events.first)
            #expect(event.kind == "answer" && event.payload.contains(#""dismissed":true"#))
        }

        @Test func aFailedWorkerRunGetsItsEventsBackAndAnEndedTaskReturnsThemToTheRouter() throws {
            let (service, source) = try inbox()
            let task = try openTask(service, source: source)
            try service.record([item("m2")], caller: .intake(sourceID: source), account: account)
            _ = try service.route(account: account)
            let delivered = try service.deliver(taskID: task, account: account)
            #expect(!delivered.isEmpty)
            try service.settleDelivery(taskID: task, account: account, succeeded: false)
            #expect(try service.route(account: account).tasksToDeliver == [task])

            try service.finishTask(taskID: task, status: "dismissed", caller: .router, account: account)
            try service.returnToRouter(taskID: task, account: account)
            #expect(try service.routerInput(account: account).events.map(\.externalID) == ["m2"])
        }

        @Test func aSuggestedTaskHoldsItsEventsUntilTheUserDecides() throws {
            let (service, source) = try inbox()
            try service.record([item("m1"), item("m2", topic: "thread-2")], caller: .intake(sourceID: source), account: account)
            let events = try service.routerInput(account: account).events
            let accepted = try service.suggestTask(
                title: "Reply to Dana", instructions: "Draft a reply", eventIDs: [events[0].id], caller: .router, account: account
            )
            let declined = try service.suggestTask(
                title: "Read the newsletter", instructions: "Summarize", eventIDs: [events[1].id], caller: .router, account: account
            )
            // Held events wait for the user and never reach the Router again.
            #expect(try service.route(account: account) == .init(tasksToDeliver: [], routerNeeded: false))

            #expect(try service.answer(itemID: accepted.id, revision: 1, answer: "Go ahead", account: account))
            #expect(try service.dismiss(itemID: declined.id, revision: 1, account: account))
            let task = try #require(try service.dbQueue.read { try AgentTaskRecord.fetchOne($0) })
            #expect(task.title == "Reply to Dana" && task.instructions == "Draft a reply" && task.threadID != nil)
            #expect(try service.route(account: account).tasksToDeliver == [task.id])
            #expect(try service.dbQueue.read { try AgentEventRecord.fetchOne($0, key: events[1].id)?.status } == "processed")
            // An accepted suggestion starts its Task itself; the Router gets no answer event for it.
            #expect(try service.routerInput(account: account).events.isEmpty)
        }

        @Test func aRequestForAnOpenTaskGoesStraightToItsWorker() throws {
            let (service, source) = try inbox()
            let task = try openTask(service, source: source)
            try service.request("価格も入れて", taskID: task, account: account)
            #expect(try service.route(account: account) == .init(tasksToDeliver: [task], routerNeeded: false))
            try service.finishTask(taskID: task, status: "done", caller: .router, account: account)
            #expect(throws: AgentInboxService.Failure.self) { try service.request("もう一度", taskID: task, account: account) }
        }

        // MARK: migration

        @Test func migrationKeepsExistingChatsAndMatchesAFreshSchema() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v66_skillCurator")
            let thread = UUID().uuidString
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO chat_threads(id,accountID,title,createdAt,updatedAt) VALUES(?,'local','kept',?,?)",
                    arguments: [thread, Date(), Date()]
                )
            }

            try AppDatabaseManager.migrator.migrate(queue)

            try queue.read { db throws in
                #expect(try String.fetchOne(db, sql: "SELECT title FROM chat_threads WHERE id=?", arguments: [thread]) == "kept")
                #expect(try db.tableExists("agent_event_inbox") && (db.tableExists("agent_action_outbox")))
                #expect(try AppDatabaseManager.hasExpectedCurrentSchema(db))
            }
        }
    }
#endif
