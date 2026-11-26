#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct AgentInboxServiceTests {
        private let account = UUID.v7().uuidString

        private func inbox(allowedSenders: [String] = []) throws -> (AgentInboxService, String) {
            let queue = try AppDatabaseManager(path: ":memory:").dbQueue
            let source = UUID.v7().uuidString
            let agent = try queue.write { db in
                let agent = try AgentRecord.insertForTest(in: db)
                try AgentSourceRecord(
                    id: source, agentID: agent.id, name: "Mail", server: "gmail", instructions: "Unread mail", intervalMinutes: 15,
                    allowedSenders: String(decoding: JSONEncoder().encode(allowedSenders), as: UTF8.self), cursor: nil,
                    enabled: true, lastIntakeAt: nil, createdAt: .now, updatedAt: .now, connectionID: "gmail"
                ).insert(db)
                return agent
            }
            return (AgentInboxService(dbQueue: queue, agentID: agent.id), source)
        }

        /// One agent's inbox never shows or changes another's events, Tasks, or Items, even when given their IDs.
        @Test func anAgentReachesOnlyItsOwnEventsTasksAndItems() throws {
            let (mine, source) = try inbox()
            let other = try AgentInboxService(
                dbQueue: mine.dbQueue, agentID: mine.dbQueue.write { try AgentRecord.insertForTest(name: "Other", in: $0) }.id
            )
            try mine.record([item("a")], caller: .intake(sourceID: source))
            let event = try #require(try mine.inbox().events.first)
            let taskThread = try thread(mine)
            let task = try mine.openTask(threadID: taskThread, title: "Mine", instructions: "", eventIDs: [])
            try mine.createItem(kind: "report", title: "For me")

            let theirs = try other.inbox()
            #expect(theirs.events.isEmpty && theirs.tasks.isEmpty && theirs.items.isEmpty)
            #expect(try !other.hasUndecidedEvents() && other.recentEvents().isEmpty && other.sources().isEmpty)
            #expect(try other.tasks().active.isEmpty && other.items().isEmpty)
            #expect(throws: AgentInboxService.Failure.self) { try other.undecidedEvents([event.id]) }
            #expect(throws: AgentInboxService.Failure.self) { try other.finishTask(threadID: taskThread, status: "done") }
            #expect(throws: AgentInboxService.Failure.self) { try other.createItem(kind: "report", title: "x", threadID: taskThread) }
            try other.close(eventIDs: [event.id])
            // Handing another agent's event to its own task changes nothing either.
            try other.continueTask(threadID: taskThread, eventIDs: [event.id])
            #expect(try mine.inbox().events.map(\.id) == [event.id])
            #expect(try mine.task(task.id)?.status == "active")
            #expect(try mine.agentsWithUndecidedEvents() == [mine.agentID])
        }

        @Test(arguments: [false, true])
        func aCappedIntakeKeepsTheOriginalLowerBound(hasCursor: Bool) throws {
            let (service, source) = try inbox()
            if hasCursor { try service.commitIntake(sourceID: source, cursor: "saved-floor") }
            let start = Date.now
            let lowerBound = try service.intakeLowerBound(sourceID: source, revision: 1, now: start)
            let expected = hasCursor ? "saved-floor" : ISO8601DateFormatter().string(from: start.addingTimeInterval(-86400))
            #expect(lowerBound == expected)
            #expect(try service.intakeLowerBound(sourceID: source, revision: 1, now: start.addingTimeInterval(1200)) == expected)
            #expect(try !service.commitIntake(sourceID: source, cursor: "attempt-end", recordedCount: 20, limitReached: true))
            #expect(try service.sources().first?.cursor == expected)
            #expect(try !service.commitIntake(sourceID: source, cursor: "later-attempt", recordedCount: 20, limitReached: true))
            #expect(try service.sources().first?.cursor == expected)
            #expect(try service.commitIntake(sourceID: source, cursor: "finished-through"))
            #expect(try service.sources().first?.cursor == "finished-through")
        }

        private func item(_ id: String, topic: String = "thread-1", direct _: Bool = true) -> AgentInboxService.IntakeItem {
            .init(key: id, topic: topic, note: "Hello …", ref: .object(["messageId": .string(id)]), sender: "a@example.com")
        }

        private func eventIDs(_ service: AgentInboxService, status: String) throws -> [String] {
            try service.dbQueue.read {
                try String.fetchAll(
                    $0,
                    sql: "SELECT id FROM agent_event_inbox WHERE handledAt IS \(status == "processed" ? "NOT NULL" : "NULL") ORDER BY createdAt, id"
                )
            }
        }

        /// A thread for a Task to belong to; Super Agent launches it before Dahlia records the Task.
        private func thread(_ service: AgentInboxService) throws -> String {
            let id = UUID.v7().uuidString
            try ChatThreadStore(dbQueue: service.dbQueue).createThread(ChatThreadRecord(
                id: id, accountID: account, title: "Reply", createdAt: .now, updatedAt: .now
            ))
            return id
        }

        /// A Task is a thread Super Agent launched. Events it hands over go to the Task; a finished Task is in progress
        /// again once Super Agent sends to its thread; only a Task's thread can be finished.
        @Test func aTaskIsALaunchedThreadThatOnlySuperAgentOrTheUserEnds() throws {
            let (service, source) = try inbox()
            try service.record([item("m1"), item("m2"), item("m3")], caller: .intake(sourceID: source))
            let waiting = try eventIDs(service, status: "unassigned")
            let threadID = try thread(service)

            let task = try service.openTask(threadID: threadID, title: "Reply", instructions: "Answer m1", eventIDs: [waiting[0]])
            #expect(try eventIDs(service, status: "processed") == [waiting[0]])
            #expect(try service.dbQueue
                .read { try String.fetchOne($0, sql: "SELECT taskID FROM agent_event_inbox WHERE id=?", arguments: [waiting[0]]) } == task.id)
            // An event already handed over is not waiting any more.
            #expect(throws: AgentInboxService.Failure.self) { try service.undecidedEvents([waiting[0]]) }

            try service.finishTask(threadID: threadID, status: "done")
            #expect(try service.tasks().finished.map(\.id) == [task.id])
            try service.continueTask(threadID: threadID, eventIDs: [waiting[1]])
            #expect(try service.task(threadID: threadID)?.status == "active")
            #expect(try service.dbQueue
                .read { try String.fetchOne($0, sql: "SELECT taskID FROM agent_event_inbox WHERE id=?", arguments: [waiting[1]]) } == task.id)

            try service.close(eventIDs: [waiting[2]])
            #expect(try !service.hasUndecidedEvents())
            #expect(throws: AgentInboxService.Failure.self) {
                try service.finishTask(threadID: UUID.v7().uuidString, status: "done")
            }
            #expect(throws: AgentInboxService.Failure.self) { try service.finishTask(threadID: threadID, status: "later") }
        }

        @Test(arguments: [false, true])
        func finishedTasksPageNewestFirst(tiedTimes: Bool) throws {
            let (service, _) = try inbox()
            var finished: [AgentTaskRecord] = []
            for index in 0 ..< 3 {
                let threadID = try thread(service)
                var task = try service.openTask(threadID: threadID, title: "T\(index)", instructions: "", eventIDs: [])
                task.updatedAt = Date(timeIntervalSince1970: Double(1000 + (tiedTimes ? 0 : index)))
                try service.finishTask(threadID: threadID, status: "done", now: task.updatedAt)
                finished.append(task)
            }
            let expected = finished.sorted {
                $0.updatedAt == $1.updatedAt ? $0.id > $1.id : $0.updatedAt > $1.updatedAt
            }.map(\.id)
            let first = try service.tasks(limit: 2)
            #expect(first.finished.map(\.id) == Array(expected.prefix(2)))
            let expanded = try service.tasks(limit: 4)
            #expect(expanded.finished.map(\.id) == expected)
            #expect(expanded.finished.count < 4)
        }

        /// An Item ties to a Task's thread; the user's answer reaches Super Agent once as an event naming that thread, and an
        /// answer to an older revision changes nothing. A suggestion dismissed recently is not made again.
        @Test func anAnswerReachesSuperAgentOnceAndAStaleOneChangesNothing() throws {
            let (service, _) = try inbox()
            let threadID = try thread(service)
            let task = try service.openTask(threadID: threadID, title: "Reply", instructions: "", eventIDs: [])
            #expect(throws: AgentInboxService.Failure.self) {
                try service.createItem(kind: "question", title: "Send?", threadID: UUID.v7().uuidString)
            }
            let question = try service.createItem(kind: "question", title: "Send?", options: ["Yes", "No"], threadID: threadID)
            #expect(question.taskID == task.id)
            #expect(try !service.answer(itemID: question.id, revision: 2, answer: "Yes"))
            #expect(try service.answer(itemID: question.id, revision: 1, answer: "Yes"))
            #expect(try !service.answer(itemID: question.id, revision: 1, answer: "No"))
            let answers = try service.dbQueue
                .read { try AgentEventRecord.fetchAll($0, sql: "SELECT * FROM agent_event_inbox WHERE sourceID IS NULL") }
            #expect(answers.count == 1 && answers[0].note.contains("Yes") && answers[0].handledAt == nil)
            #expect(answers[0].ref?.contains(threadID) == true)
            try service.close(eventIDs: [answers[0].id])
            let closed = try #require(try service.recentEvents().first)
            #expect(closed.handledAt != nil && closed.taskID == nil && closed.ref?.contains(threadID) == true)

            // A report closes without an event; a dismissed suggestion blocks the same one for a while.
            let report = try service.createItem(kind: "report", title: "Done")
            #expect(try service.dismiss(itemID: report.id, revision: 1))
            let suggestion = try service.createItem(kind: "suggestion", title: "Reply to Dana?")
            #expect(try service.dismiss(itemID: suggestion.id, revision: 1))
            #expect(throws: AgentInboxService.Failure.self) { try service.createItem(kind: "suggestion", title: "Reply to Dana?") }
            #expect(try service.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM agent_event_inbox WHERE sourceID IS NULL") } == 1)
        }

        @Test(arguments: ["instructions", "disabled", "deleted"])
        func obsoleteIntakeCannotPublishOrAdvanceItsSource(change: String) throws {
            let (service, id) = try inbox()
            var source = try #require(try service.sources().first)
            if change == "deleted" {
                try service.deleteSource(id: id)
            } else {
                source.instructions = "Read a different range"
                source.enabled = change != "disabled"
                try service.saveSource(source)
            }
            #expect(throws: AgentInboxService.Failure.self) {
                try service.record([item("old")], caller: .intake(sourceID: id, revision: 1))
            }
            #expect(throws: AgentInboxService.Failure.self) {
                try service.commitIntake(sourceID: id, revision: 1, cursor: "stale")
            }
            #expect(try service.recentEvents().isEmpty)
            #expect(try service.sources().first?.cursor == nil)
            if change == "instructions" {
                let current = try #require(try service.sources().first)
                #expect(current.revision == 2)
                try service.record([item("fresh")], caller: .intake(sourceID: id, revision: current.revision))
                #expect(try service.commitIntake(sourceID: id, revision: current.revision, cursor: "fresh"))
            }
        }

        @Test(arguments: [false, true])
        func savingAStaleSettingsSnapshotPreservesRuntimeProgress(toggle: Bool) throws {
            let (service, id) = try inbox()
            var snapshot = try #require(try service.sources().first)
            let createdAt = snapshot.createdAt
            let now = Date(timeIntervalSince1970: 100_000)
            #expect(try service.commitIntake(sourceID: id, cursor: "latest", now: now))
            snapshot.name = "Updated"
            snapshot.enabled = !toggle
            snapshot.createdAt = .distantPast
            try service.saveSource(snapshot)
            let saved = try #require(try service.sources().first)
            #expect(saved.name == "Updated" && saved.enabled == !toggle && saved.revision == 2)
            #expect(saved.cursor == "latest" && saved.lastIntakeAt == now && saved.createdAt == createdAt)
        }

        /// Work the user asked for opens with their words as its first event, saved with the task; a task needs one or the other.
        @Test func intakeKeepsOnlySelectedSignalsAndAllowedSenders() throws {
            let (service, source) = try inbox(allowedSenders: ["a@example.com"])
            var stranger = item("m3")
            stranger.sender = "spam@example.com"
            let first = try service.record([item("m1"), item("m2", direct: false), stranger], caller: .intake(sourceID: source))
            let again = try service.record([item("m1")], caller: .intake(sourceID: source))

            #expect(first == ["m1": "recorded", "m2": "recorded", "m3": "blocked"])
            #expect(again == ["m1": "duplicate"])
            #expect(try service.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM agent_event_inbox") } == 2)
            let event = try #require(try service.dbQueue.read {
                try AgentEventRecord.fetchOne($0, sql: "SELECT * FROM agent_event_inbox WHERE key='m1'")
            })
            #expect(event.ref == #"{"messageId":"m1"}"#)
            #expect(try service.hasUndecidedEvents())
            #expect(try eventIDs(service, status: "unassigned").count == 2)
        }

        @Test func readPositionMovesAfterSelectionEvenWhenNothingIsRecorded() throws {
            let (service, source) = try inbox()
            try service.record([item("m1")], caller: .intake(sourceID: source))

            #expect(try service.commitIntake(sourceID: source, cursor: "page-2", readCount: 2, recordedCount: 1))
            #expect(try service.dbQueue.read { try AgentSourceRecord.fetchOne($0, key: source)?.cursor } == "page-2")
            try service.record([item("m2", direct: false)], caller: .intake(sourceID: source))
            #expect(try service.commitIntake(sourceID: source, cursor: "page-2"))
            #expect(try service.dbQueue.read { try AgentSourceRecord.fetchOne($0, key: source)?.cursor } == "page-2")
        }

        @Test func recordToolArgumentsAreBoundedAndOnlyWebLinksAreKept() throws {
            let long = String(repeating: "あ", count: 2000)
            let items = try AgentInboxService.items(from: .object(["items": .array([
                .object([
                    "key": .string(" m1 "), "note": .string(long), "subject": .string(long), "url": .string("javascript:alert(1)"),
                    "occurred_at": .string("2026-11-19T09:00:00Z"), "direct": .bool(true), "ref": .object(["id": .string("m1")]),
                ]),
                .object(["key": .string("m2"), "note": .string("Reason"), "url": .string("https://mail.example.com/m2"), "ref": .null]),
            ])]))

            #expect(items.map(\.key) == ["m1", "m2"])
            #expect(items[0].note.count == AgentInboxService.noteLimit)
            #expect(items[0].occurredAt == Date(timeIntervalSince1970: 1_795_078_800))
            #expect(items[0].ref == .object(["id": .string("m1")]) && items[1].ref == nil)
            for bad: JSONValue in [
                .object([:]), .object(["items": .array([.object(["subject": .string("no id")])])]),
                .object(["items": .array([.object(["key": .string("m3"), "ref": .string(String(repeating: "x", count: 5000))])])]),
            ] {
                #expect(throws: AgentInboxService.Failure.self) { try AgentInboxService.items(from: bad) }
            }
        }

        @Test func sourcesAreDueOnceTheirIntervalHasPassed() throws {
            let (service, source) = try inbox()
            let now = Date(timeIntervalSince1970: 100_000)
            #expect(try service.dueSources(now: now).map(\.id) == [source])
            #expect(try service.commitIntake(sourceID: source, cursor: "c", now: now))
            #expect(try service.dueSources(now: now.addingTimeInterval(14 * 60)).isEmpty)
            #expect(try service.dueSources(now: now.addingTimeInterval(15 * 60)).map(\.id) == [source])
            var disabled = try #require(try service.sources().first)
            disabled.enabled = false
            try service.saveSource(disabled)
            #expect(try service.dueSources(now: now.addingTimeInterval(3600)).isEmpty)
            disabled.intervalMinutes = 1
            #expect(throws: AgentInboxService.Failure.self) { try service.saveSource(disabled) }
        }

        @Test func shortAnswerNotesRetainTheCompleteAnswerInTheirReference() throws {
            let (service, _) = try inbox()
            let question = try service.createItem(kind: "question", title: "Details?")
            let answer = String(repeating: "detail ", count: 200)
            try service.answer(itemID: question.id, revision: 1, answer: answer)
            let event = try #require(try service.inbox().events.first)
            #expect(event.note.count == AgentInboxService.noteLimit)
            let ref = try JSONDecoder().decode(JSONValue.self, from: Data((event.ref ?? "{}").utf8))
            #expect(ref.objectValue?["answer"]?.stringValue == answer.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        @Test func intakeCannotHideSignalsInTheFutureOrDoubleCountDuplicateKeys() throws {
            let (service, source) = try inbox()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var signal = item("a")
            signal.occurredAt = now.addingTimeInterval(86400)
            let statuses = try service.record([signal, signal], caller: .intake(sourceID: source), now: now)
            #expect(statuses == ["a": "recorded"])
            #expect(try service.inbox(now: now).events.first?.occurredAt == now)
        }

        @Test func futureSignalsStayHiddenAndCleanupUsesHandledTime() throws {
            let (service, source) = try inbox()
            let now = Date.now
            let future = AgentEventRecord(
                id: UUID.v7().uuidString,
                agentID: service.agentID,
                sourceID: nil,
                key: nil,
                topic: nil,
                note: "Later",
                ref: nil,
                occurredAt: now.addingTimeInterval(60),
                taskID: nil,
                handledAt: nil,
                createdAt: now
            )
            try service.dbQueue.write { try future.insert($0) }
            #expect(try service.inbox(now: now).events.isEmpty)
            #expect(try !service.hasUndecidedEvents(now: now))
            #expect(try service.hasUndecidedEvents(now: now.addingTimeInterval(60)))
            let old = now.addingTimeInterval(-31 * 86400)
            try service.record([item("old"), item("unhandled")], caller: .intake(sourceID: source), now: old)
            let waiting = try service.inbox(now: now).events
            let threadID = try thread(service)
            let task = try service.openTask(threadID: threadID, title: "Survives", instructions: "Keep", eventIDs: [waiting[0].id], now: old)
            try service.dbQueue.write { try $0.execute(sql: "DELETE FROM chat_threads WHERE id=?", arguments: [threadID]) }
            #expect(try service.task(task.id)?.threadID == nil)
            try service.finishTask(taskID: task.id, status: "done")
            try service.cleanEvents(now: now)
            #expect(try service.recentEvents().count == 2)
            #expect(try service.task(task.id)?.title == "Survives")
        }

        @Test func matchingTopicsSuggestActiveThreadsWithoutLinkingEvents() throws {
            let (service, source) = try inbox()
            try service.record([item("a"), item("b"), item("c")], caller: .intake(sourceID: source))
            let events = try service.inbox().events
            let threadID = try thread(service)
            try service.openTask(threadID: threadID, title: "Reply", instructions: "", eventIDs: Array(events.prefix(2).map(\.id)))
            #expect(try service.relatedThreads(for: [events[2]])[events[2].id] == [threadID])
            #expect(try service.inbox().events.first?.taskID == nil)
        }

        @Test func intakeProfileReadsOnlyItsSourceAndRecords() {
            #expect(PiExecutionProfile.intake.allows("event_record"))
            #expect(PiExecutionProfile.intake.allows("mcp__gmail__search_messages", readOnly: true))
            #expect(!PiExecutionProfile.intake.allows("mcp__gmail__send_message"))
            #expect(!PiExecutionProfile.intake.allows("mcp__dahlia__get_meeting", readOnly: true))
            #expect(!PiExecutionProfile.intake.allows("read") && PiExecutionProfile.intake.fileTools.isEmpty)
        }

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
                #expect(try db.tableExists("agent_event_inbox") && (db.tableExists("agent_tasks")))
                #expect(try AppDatabaseManager.hasExpectedCurrentSchema(db))
            }
        }
    }
#endif
