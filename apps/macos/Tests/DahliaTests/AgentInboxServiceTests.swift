#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct AgentInboxServiceTests {
        private let account = UUID.v7().uuidString

        @Test func botThreadIdentityIsScopedToItsDataDirectory() throws {
            let suite = "AgentBotSettingsTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let directories = [
                DahliaApplicationSupport.directoryURL(profile: .production, applicationSupportDirectory: root),
                DahliaApplicationSupport.directoryURL(profile: .development, developmentDirectory: root.appending(path: "worktree-a")),
                DahliaApplicationSupport.directoryURL(profile: .development, developmentDirectory: root.appending(path: "worktree-b")),
            ]
            let keys = directories.map { AgentBotSettings.botThreadKey(for: account, dataDirectory: $0) }
            #expect(Set(keys).count == 3)
            for (index, key) in keys.enumerated() {
                defaults.set("thread-\(index)", forKey: key)
            }
            defaults.set("foreign", forKey: AgentBotSettings.legacyBotThreadKey(for: account))
            #expect(keys.enumerated().allSatisfy { defaults.string(forKey: $0.element) == "thread-\($0.offset)" })
            #expect(AgentBotSettings.botThreadKey(for: account, dataDirectory: directories[1].appending(path: ".")) == keys[1])
        }

        @Test func legacyBotIdentityIsAdoptedOnlyByItsOwningDatabase() throws {
            let own = try AppDatabaseManager(path: ":memory:").dbQueue
            let foreign = try AppDatabaseManager(path: ":memory:").dbQueue
            let key = AgentBotSettings.botThreadKey(for: account)
            let legacy = AgentBotSettings.legacyBotThreadKey(for: account)
            defer {
                UserDefaults.standard.removeObject(forKey: key)
                UserDefaults.standard.removeObject(forKey: legacy)
            }
            let thread = ChatThreadRecord(id: UUID.v7().uuidString, accountID: account, title: "Current", createdAt: .now, updatedAt: .now)
            try own.write { try thread.insert($0) }
            UserDefaults.standard.set(thread.id, forKey: legacy)
            #expect(try foreign.write { try AgentInboxService.adoptLegacyBotThread(account: account, in: $0) } == nil)
            #expect(UserDefaults.standard.string(forKey: key) == nil)
            #expect(try own.write { try AgentInboxService.adoptLegacyBotThread(account: account, in: $0) } == thread.id)
            #expect(AgentBotSettings.botThread(for: account) == thread.id)
            // Another profile can still migrate the old setting, but can no longer change this profile's identity.
            UserDefaults.standard.set("another-database-thread", forKey: legacy)
            #expect(AgentBotSettings.botThread(for: account) == thread.id)
        }

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
            try service.record([item("m1"), item("m2"), item("m3")], caller: .intake(sourceID: source), account: account)
            let waiting = try eventIDs(service, status: "unassigned")
            let threadID = try thread(service)

            let task = try service.openTask(threadID: threadID, title: "Reply", instructions: "Answer m1", eventIDs: [waiting[0]], account: account)
            #expect(try eventIDs(service, status: "processed") == [waiting[0]])
            #expect(try service.dbQueue
                .read { try String.fetchOne($0, sql: "SELECT taskID FROM agent_event_inbox WHERE id=?", arguments: [waiting[0]]) } == task.id)
            // An event already handed over is not waiting any more.
            #expect(throws: AgentInboxService.Failure.self) { try service.undecidedEvents([waiting[0]], account: account) }

            try service.finishTask(threadID: threadID, status: "done", account: account)
            #expect(try service.tasks(account: account).finished.map(\.id) == [task.id])
            try service.continueTask(threadID: threadID, eventIDs: [waiting[1]], account: account)
            #expect(try service.task(threadID: threadID, account: account)?.status == "active")
            #expect(try service.dbQueue
                .read { try String.fetchOne($0, sql: "SELECT taskID FROM agent_event_inbox WHERE id=?", arguments: [waiting[1]]) } == task.id)

            try service.close(eventIDs: [waiting[2]], account: account)
            #expect(try !service.hasUndecidedEvents(account: account))
            #expect(throws: AgentInboxService.Failure.self) {
                try service.finishTask(threadID: UUID.v7().uuidString, status: "done", account: account)
            }
            #expect(throws: AgentInboxService.Failure.self) { try service.finishTask(threadID: threadID, status: "later", account: account) }
        }

        @Test func finishedTasksPageNewestFirst() throws {
            let (service, _) = try inbox()
            var threads: [String] = []
            for index in 0 ..< 3 {
                let threadID = try thread(service)
                threads.append(threadID)
                try service.openTask(threadID: threadID, title: "T\(index)", instructions: "", eventIDs: [], account: account)
                try service.finishTask(threadID: threadID, status: "done", account: account, now: Date(timeIntervalSince1970: Double(1000 + index)))
            }
            let first = try service.tasks(account: account, limit: 2)
            #expect(first.finished.map(\.threadID) == [threads[2], threads[1]])
            let next = try service.tasks(account: account, finishedBefore: first.finished.last?.updatedAt, limit: 2)
            #expect(next.active.isEmpty && next.finished.map(\.threadID) == [threads[0]])
        }

        /// An Item ties to a Task's thread; the user's answer reaches Super Agent once as an event naming that thread, and an
        /// answer to an older revision changes nothing. A suggestion dismissed recently is not made again.
        @Test func anAnswerReachesSuperAgentOnceAndAStaleOneChangesNothing() throws {
            let (service, _) = try inbox()
            let threadID = try thread(service)
            let task = try service.openTask(threadID: threadID, title: "Reply", instructions: "", eventIDs: [], account: account)
            #expect(throws: AgentInboxService.Failure.self) {
                try service.createItem(kind: "question", title: "Send?", threadID: UUID.v7().uuidString, account: account)
            }
            let question = try service.createItem(kind: "question", title: "Send?", options: ["Yes", "No"], threadID: threadID, account: account)
            #expect(question.taskID == task.id)
            #expect(try !service.answer(itemID: question.id, revision: 2, answer: "Yes", account: account))
            #expect(try service.answer(itemID: question.id, revision: 1, answer: "Yes", account: account))
            #expect(try !service.answer(itemID: question.id, revision: 1, answer: "No", account: account))
            let answers = try service.dbQueue.read { try AgentEventRecord.fetchAll($0, sql: "SELECT * FROM agent_event_inbox WHERE kind='answer'") }
            #expect(answers.count == 1 && answers[0].excerpt == "Yes" && answers[0].status == "unassigned")
            #expect(answers[0].payload.contains(threadID))

            // A report closes without an event; a dismissed suggestion blocks the same one for a while.
            let report = try service.createItem(kind: "report", title: "Done", account: account)
            #expect(try service.dismiss(itemID: report.id, revision: 1, account: account))
            let suggestion = try service.createItem(kind: "suggestion", title: "Reply to Dana?", account: account)
            #expect(try service.dismiss(itemID: suggestion.id, revision: 1, account: account))
            #expect(throws: AgentInboxService.Failure.self) { try service.createItem(kind: "suggestion", title: "Reply to Dana?", account: account) }
            #expect(try service.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM agent_event_inbox WHERE kind='answer'") } == 1)
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

        @Test(arguments: [false, true])
        func savingAStaleSettingsSnapshotPreservesRuntimeProgress(toggle: Bool) throws {
            let (service, id) = try inbox()
            var snapshot = try #require(try service.sources(account: account).first)
            let createdAt = snapshot.createdAt
            let now = Date(timeIntervalSince1970: 100_000)
            #expect(try service.commitIntake(sourceID: id, account: account, cursor: "latest", seen: [], now: now))
            try service.markGap(sourceID: id, account: account, now: now)
            snapshot.name = "Updated"
            snapshot.enabled = !toggle
            snapshot.createdAt = .distantPast
            try service.saveSource(snapshot)
            let saved = try #require(try service.sources(account: account).first)
            #expect(saved.name == "Updated" && saved.enabled == !toggle && saved.revision == 2)
            #expect(saved.cursor == "latest" && saved.lastIntakeAt == now && saved.gapDetectedAt == now && saved.createdAt == createdAt)
        }

        /// Work the user asked for opens with their words as its first event, saved with the task; a task needs one or the other.
        @Test func intakeKeepsOneRowPerItemAndSievesBeforeSuperAgent() throws {
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
            #expect(try service.hasUndecidedEvents(account: account))
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
