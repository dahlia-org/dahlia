import DahliaRuntimeSupport
import Foundation
import GRDB

/// The always-on agent's inbox, and the only owner of its event, Task, and Item state. Intake, Super Agent, and the user
/// reach it only through these methods. The native side sets `Caller` from the Pi session that made the call, never from
/// what the model says it is.
struct AgentInboxService: Sendable {
    enum Caller: Sendable, Equatable {
        case intake(sourceID: String, revision: Int = 1)
    }

    struct IntakeItem: Sendable, Equatable {
        var key: String
        var topic: String?
        var note: String
        var ref: JSONValue?
        var occurredAt: Date?
        /// Used only to enforce the source allowlist; never persisted.
        var sender: String?
    }

    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    static let titleLimit = 140
    static let bodyLimit = 4000
    static let optionLimit = 5
    static let dismissalMemory: TimeInterval = 30 * 86400

    let dbQueue: any DatabaseWriter

    // MARK: - intake

    static let noteLimit = 500
    static let fieldLimit = 300
    static let refLimit = 4096

    static func items(from payload: JSONValue) throws -> [IntakeItem] {
        guard let rows = payload.objectValue?["items"]?.arrayValue, rows.count <= 100 else {
            throw Failure(message: "Pass at most 100 items as an array.")
        }
        return try rows.map { row in
            let fields = row.objectValue ?? [:]
            func text(_ key: String, _ limit: Int = fieldLimit) -> String? {
                fields[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map { String($0.prefix(limit)) }
            }
            guard let key = text("key"), let note = text("note", noteLimit) else { throw Failure(message: "Every event needs key and note.") }
            let ref = fields["ref"].flatMap { $0 == .null ? nil : $0 }
            if let ref, try Self.text(ref).utf8.count > refLimit { throw Failure(message: "ref is too large.") }
            return IntakeItem(
                key: key,
                topic: text("topic"),
                note: note,
                ref: ref,
                occurredAt: text("occurred_at").flatMap { try? Date($0, strategy: .iso8601) },
                sender: text("sender")
            )
        }
    }

    /// Enabled Sources whose interval has passed since they last read successfully, oldest first.
    func dueSources(now: Date = .now) throws -> [AgentSourceRecord] {
        try dbQueue.read { db in
            try AgentSourceRecord.fetchAll(
                db,
                sql: "SELECT * FROM agent_event_sources WHERE enabled=1 AND kind='mcp' ORDER BY COALESCE(lastIntakeAt, createdAt), id"
            )
        }.filter { ($0.lastIntakeAt ?? .distantPast).addingTimeInterval(Double($0.intervalMinutes) * 60) <= now }
    }

    func sources() throws -> [AgentSourceRecord] {
        try dbQueue.read {
            try AgentSourceRecord.fetchAll(
                $0,
                sql: "SELECT * FROM agent_event_sources ORDER BY createdAt, id"
            )
        }
    }

    func saveSource(_ source: AgentSourceRecord, now: Date = .now) throws {
        guard ["mcp", "calendar"].contains(source.kind), source.intervalMinutes >= 5 else {
            throw Failure(message: "A source reads at most every 5 minutes.")
        }
        if source.kind == "calendar" {
            guard source.dailyAt != nil || source.leadHours != nil,
                  source.dailyAt.map({ Self.dailyComponents($0) != nil }) ?? true,
                  source.leadHours.map({ $0.isFinite && $0 > 0 && $0 < 168 }) ?? true else {
                throw Failure(message: L10n.agentCalendarInvalidSchedule)
            }
        }
        try dbQueue.write { db in
            var source = source
            if let previous = try AgentSourceRecord.fetchOne(db, key: source.id) {
                guard previous.kind == source.kind, previous.server == source.server, previous.connectionID == source.connectionID else {
                    throw Failure(message: "Create a new Source to use another server.")
                }
                source.revision = previous.revision + 1
                source.cursor = previous.cursor
                source.lastIntakeAt = previous.lastIntakeAt
                source.lastReadCount = previous.lastReadCount
                source.lastRecordedCount = previous.lastRecordedCount
                source.createdAt = previous.createdAt
            } else {
                source.revision = 1
            }
            try source.save(db)
            if source.kind == "calendar" {
                // Turning off a schedule cancels signals that have not happened yet; arrived events remain decisions.
                if !source.enabled {
                    try db.execute(
                        sql: "DELETE FROM agent_event_inbox WHERE sourceID=? AND handledAt IS NULL AND occurredAt>?",
                        arguments: [source.id, now]
                    )
                } else {
                    if source.dailyAt == nil {
                        try db.execute(
                            sql: "DELETE FROM agent_event_inbox WHERE sourceID=? AND handledAt IS NULL AND key LIKE 'daily:%' AND occurredAt>?",
                            arguments: [source.id, now]
                        )
                    }
                    if source.leadHours == nil {
                        try db.execute(
                            sql: "DELETE FROM agent_event_inbox WHERE sourceID=? AND handledAt IS NULL AND key LIKE 'meeting:%' AND occurredAt>?",
                            arguments: [source.id, now]
                        )
                    }
                }
            }
        }
    }

    /// Deleting a Source removes the events it recorded.
    func deleteSource(id: String) throws {
        try dbQueue.write {
            try $0.execute(sql: "DELETE FROM agent_event_sources WHERE id=?", arguments: [id])
        }
    }

    /// The most recently recorded signals for the side panel.
    func recentEvents(limit: Int = 50) throws -> [AgentEventRecord] {
        try dbQueue.read {
            try AgentEventRecord.fetchAll(
                $0,
                sql: "SELECT * FROM agent_event_inbox  ORDER BY createdAt DESC, id DESC LIMIT ?",
                arguments: [limit]
            )
        }
    }

    func isPaused() throws -> Bool {
        try dbQueue.read { try Self.isPaused(in: $0) }
    }

    /// Records selected signals. Duplicates keep their first row; blocked senders leave no row.
    @discardableResult
    func record(_ items: [IntakeItem], caller: Caller, remaining: Int = 20, now: Date = .now) throws -> [String: String] {
        guard case let .intake(sourceID, revision) = caller else { throw Failure(message: "Only an intake run records items.") }
        return try dbQueue.write { db in
            let source = try Self.currentSource(sourceID, revision: revision, in: db)
            let allowed = try Set(JSONDecoder().decode([String].self, from: Data(source.allowedSenders.utf8)).map { $0.lowercased() })
            var statuses: [String: String] = [:]
            var inserted = 0
            for item in items {
                if statuses[item.key] == "recorded" { continue }
                if try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM agent_event_inbox WHERE sourceID=? AND key=?)",
                    arguments: [sourceID, item.key]
                ) == true {
                    statuses[item.key] = "duplicate"
                    continue
                }
                guard allowed.isEmpty || allowed.contains(item.sender?.lowercased() ?? "") else {
                    statuses[item.key] = "blocked"
                    continue
                }
                guard inserted < min(20, max(0, remaining)) else {
                    statuses[item.key] = "limit"
                    continue
                }
                let event = try AgentEventRecord(
                    id: UUID.v7().uuidString, sourceID: sourceID, key: item.key, topic: item.topic,
                    note: String(item.note.prefix(Self.noteLimit)), ref: item.ref.map(Self.text), occurredAt: min(item.occurredAt ?? now, now),
                    taskID: nil, handledAt: nil, createdAt: now
                )
                try event.insert(db, onConflict: .ignore)
                if db.changesCount == 1 { inserted += 1 }
                statuses[item.key] = db.changesCount == 1 ? "recorded" : "duplicate"
            }
            return statuses
        }
    }

    /// Successful selection need not record every read item. At the cap the next run rereads the same range.
    @discardableResult
    func commitIntake(
        sourceID: String,
        revision: Int = 1,
        cursor: String?,
        readCount: Int = 0,
        recordedCount: Int = 0,
        limitReached: Bool = false,
        now: Date = .now
    ) throws -> Bool {
        try dbQueue.write { db in
            var source = try Self.currentSource(sourceID, revision: revision, in: db)
            if !limitReached { source.cursor = cursor }
            source.lastReadCount = readCount
            source.lastRecordedCount = recordedCount
            source.lastIntakeAt = now
            source.updatedAt = now
            try source.update(db)
            return !limitReached
        }
    }

    // MARK: - Super Agent

    /// The events nobody decided on yet, oldest first, the open Tasks, and the Items the user has not closed: what
    /// `inbox_read` shows Super Agent.
    func inbox(now: Date = .now) throws -> (events: [AgentEventRecord], tasks: [AgentTaskRecord], items: [AgentItemRecord]) {
        try dbQueue.read { db in
            try (
                AgentEventRecord.fetchAll(
                    db, sql: "SELECT * FROM agent_event_inbox WHERE handledAt IS NULL AND occurredAt<=? ORDER BY occurredAt, id LIMIT 50",
                    arguments: [now]
                ),
                AgentTaskRecord.fetchAll(
                    db, sql: "SELECT * FROM agent_tasks WHERE status='active' ORDER BY updatedAt DESC LIMIT 30"
                ),
                AgentItemRecord.fetchAll(
                    db, sql: "SELECT * FROM agent_user_inbox WHERE status='open' ORDER BY createdAt DESC LIMIT 30"
                )
            )
        }
    }

    func hasUndecidedEvents(now: Date = .now) throws -> Bool {
        try dbQueue.read {
            try Bool.fetchOne(
                $0,
                sql: "SELECT EXISTS(SELECT 1 FROM agent_event_inbox WHERE handledAt IS NULL AND occurredAt<=?)", arguments: [now]
            )
                ?? false
        }
    }

    /// Topic matches are hints only; the bot decides whether to hand the event to that thread.
    func relatedThreads(for events: [AgentEventRecord]) throws -> [String: [String]] {
        try dbQueue.read { db in
            var result: [String: [String]] = [:]
            for event in events {
                guard let topic = event.topic else { continue }
                result[event.id] = try String.fetchAll(db, sql: """
                SELECT DISTINCT t.threadID FROM agent_tasks t JOIN agent_event_inbox e ON e.taskID=t.id
                WHERE t.status='active' AND t.threadID IS NOT NULL AND e.topic=? AND e.sourceID IS ?
                ORDER BY t.threadID
                """, arguments: [topic, event.sourceID])
            }
            return result
        }
    }

    /// Undecided events by ID, for Super Agent to hand to a thread; an ID that is not one is an error the model sees.
    func undecidedEvents(_ ids: [String]) throws -> [AgentEventRecord] {
        try dbQueue.read { db in
            try ids.map { id in
                guard let event = try AgentEventRecord.fetchOne(db, key: id), event.handledAt == nil, event.occurredAt <= .now
                else { throw Failure(message: "Event \(id) is not waiting for a decision.") }
                return event
            }
        }
    }

    /// Makes a thread Super Agent launched into a Task, and marks the events it was handed as gone to it.
    @discardableResult
    func openTask(threadID: String, title: String, instructions: String, eventIDs: [String], now: Date = .now) throws
        -> AgentTaskRecord {
        try dbQueue.write {
            try Self.openTask(threadID: threadID, title: title, instructions: instructions, eventIDs: eventIDs, now: now, in: $0)
        }
    }

    @discardableResult
    static func openTask(
        threadID: String, title: String, instructions: String, eventIDs: [String], now: Date = .now, in db: Database
    ) throws -> AgentTaskRecord {
        let task = AgentTaskRecord(
            id: UUID.v7().uuidString, title: String(title.prefix(Self.titleLimit)),
            instructions: String(instructions.prefix(Self.bodyLimit)), threadID: threadID, status: "active", createdAt: now, updatedAt: now
        )
        try task.insert(db)
        try Self.process(eventIDs, taskID: task.id, now: now, in: db)
        return task
    }

    /// Super Agent sent more to a Task's thread: the events go to it, and a finished Task is in progress again.
    func continueTask(threadID: String, eventIDs: [String], now: Date = .now) throws {
        try dbQueue.write { try Self.continueTask(threadID: threadID, eventIDs: eventIDs, now: now, in: $0) }
    }

    static func continueTask(threadID: String, eventIDs: [String], now: Date = .now, in db: Database) throws {
        guard let task = try AgentTaskRecord.fetchOne(db, sql: "SELECT * FROM agent_tasks WHERE threadID=?", arguments: [threadID]) else {
            try process(eventIDs, taskID: nil, now: now, in: db)
            return
        }
        try db.execute(sql: "UPDATE agent_tasks SET status='active', updatedAt=? WHERE id=?", arguments: [now, task.id])
        try Self.process(eventIDs, taskID: task.id, now: now, in: db)
    }

    /// Ends a Task without requiring its thread to still exist.
    func finishTask(taskID: String, status: String, now: Date = .now) throws {
        guard ["done", "dismissed"].contains(status) else { throw Failure(message: "Finish a task as done or dismissed.") }
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE agent_tasks SET status=?, updatedAt=? WHERE id=?", arguments: [status, now, taskID])
            guard db.changesCount > 0 else { throw Failure(message: "Task not found.") }
        }
    }

    func finishTask(threadID: String, status: String, now: Date = .now) throws {
        guard let task = try task(threadID: threadID) else { throw Failure(message: "That thread is not a task.") }
        try finishTask(taskID: task.id, status: status, now: now)
    }

    /// Retain undecided signals, including future ones; task history outlives its handled events.
    func cleanEvents(now: Date = .now) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM agent_event_inbox WHERE handledAt<?", arguments: [now.addingTimeInterval(-30 * 86400)])
        }
    }

    /// Events that need nothing more: noise, or ones already handled.
    func close(eventIDs: [String]) throws {
        try dbQueue.write { db in
            for id in eventIDs {
                try db.execute(sql: "UPDATE agent_event_inbox SET handledAt=?, taskID=NULL WHERE id=? AND handledAt IS NULL", arguments: [Date(), id])
            }
        }
    }

    func task(_ id: String) throws -> AgentTaskRecord? {
        try dbQueue.read { try AgentTaskRecord.fetchOne($0, key: id) }
    }

    func task(threadID: String) throws -> AgentTaskRecord? {
        try dbQueue.read {
            try AgentTaskRecord.fetchOne($0, sql: "SELECT * FROM agent_tasks WHERE threadID=?", arguments: [threadID])
        }
    }

    /// The account's open Tasks and the visible range of finished Tasks, in one snapshot.
    func tasks(limit: Int = 30) throws -> (active: [AgentTaskRecord], finished: [AgentTaskRecord]) {
        try dbQueue.read { db in
            try (
                AgentTaskRecord.fetchAll(db, sql: "SELECT * FROM agent_tasks WHERE status='active' ORDER BY updatedAt DESC, id DESC"),
                AgentTaskRecord.fetchAll(db, sql: """
                SELECT * FROM agent_tasks WHERE status<>'active' ORDER BY updatedAt DESC, id DESC LIMIT ?
                """, arguments: [limit])
            )
        }
    }

    /// Adopt the old unscoped pointer only in the database that actually owns it. Other profiles may still need it.
    @discardableResult
    static func adoptLegacyBotThread(account: String, in db: Database) throws -> String? {
        let key = AgentBotSettings.botThreadKey(for: account)
        guard UserDefaults.standard.string(forKey: key) == nil,
              let id = UserDefaults.standard.string(forKey: AgentBotSettings.legacyBotThreadKey(for: account)),
              try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chat_threads WHERE id=? AND accountID=?)", arguments: [id, account]) == true
        else { return nil }
        db.afterNextTransaction { _ in UserDefaults.standard.set(id, forKey: key) }
        return id
    }

    /// Super Agent's current thread, made the first time it is needed. `replacing` starts a new one in its place.
    static func botThread(account: String, now: Date, replacing: Bool = false, in db: Database) throws -> String {
        let key = AgentBotSettings.botThreadKey(for: account)
        if !replacing, let id = UserDefaults.standard.string(forKey: key),
           try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chat_threads WHERE id=? AND accountID=?)", arguments: [id, account]) == true {
            return id
        }
        if !replacing, let id = try adoptLegacyBotThread(account: account, in: db) { return id }
        let thread = ChatThreadRecord(id: UUID.v7().uuidString, accountID: account, title: L10n.agentBotName, createdAt: now, updatedAt: now)
        try thread.insert(db)
        db.afterNextTransaction { _ in UserDefaults.standard.set(thread.id, forKey: key) }
        return thread.id
    }

    // MARK: - Items

    func items() throws -> [AgentItemRecord] {
        try dbQueue.read {
            try AgentItemRecord.fetchAll(
                $0, sql: "SELECT * FROM agent_user_inbox WHERE status='open' ORDER BY createdAt DESC, id DESC"
            )
        }
    }

    /// Shows the user a question, a report, or a suggestion. A suggestion the user dismissed in the last 30 days is not
    /// made again. `threadID` ties the Item to that thread's Task, which the panel opens.
    @discardableResult
    func createItem(
        kind: String,
        title: String,
        body: String = "",
        options: [String] = [],
        recommended: Int? = nil,
        threadID: String? = nil,
        now: Date = .now
    ) throws -> AgentItemRecord {
        guard ["question", "report", "suggestion"].contains(kind) else { throw Failure(message: "Make a question, report, or suggestion.") }
        guard let title = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map({ String($0.prefix(Self.titleLimit)) })
        else { throw Failure(message: "An Item needs a title.") }
        let options = Array(options.compactMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map { String($0.prefix(Self.fieldLimit)) }
        }.prefix(Self.optionLimit))
        return try dbQueue.write { db in
            let taskID = try threadID.map { thread in
                guard let id = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM agent_tasks WHERE threadID=?",
                    arguments: [thread]
                )
                else { throw Failure(message: "That thread is not a task.") }
                return id
            }
            if kind == "suggestion", try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM agent_user_inbox WHERE kind='suggestion' AND status='dismissed' AND title=? AND updatedAt>=?)",
                arguments: [title, now.addingTimeInterval(-Self.dismissalMemory)]
            ) == true {
                throw Failure(message: "The user dismissed this suggestion recently. Do not suggest it again.")
            }
            let item = try AgentItemRecord(
                id: UUID.v7().uuidString, kind: kind, status: "open", taskID: taskID,
                title: title, body: String(body.prefix(Self.bodyLimit)), options: Self.text(.array(options.map(JSONValue.string))),
                recommended: recommended.flatMap { options.indices.contains($0) ? $0 : nil }, answer: nil, revision: 1,
                createdAt: now, updatedAt: now
            )
            try item.insert(db)
            return item
        }
    }

    /// The user's answer to the revision they saw. One transaction checks it is still open and current, saves the answer,
    /// and adds the answer event for Super Agent, so it hears once; an older revision changes nothing.
    @discardableResult
    func answer(itemID: String, revision: Int, answer: String, now: Date = .now) throws -> Bool {
        try settle(itemID: itemID, revision: revision, answer: answer, now: now)
    }

    /// Closes an Item without an answer. A dismissed question still tells Super Agent, so its thread does not wait for it.
    @discardableResult
    func dismiss(itemID: String, revision: Int, now: Date = .now) throws -> Bool {
        try settle(itemID: itemID, revision: revision, answer: nil, now: now)
    }

    private func settle(itemID: String, revision: Int, answer: String?, now: Date) throws -> Bool {
        try dbQueue.write { db in
            guard var item = try AgentItemRecord.fetchOne(db, key: itemID), item.status == "open",
                  item.revision == revision else { return false }
            let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map { String($0.prefix(Self.bodyLimit)) }
            item.answer = answer
            item.status = answer != nil || item.kind == "report" ? "done" : "dismissed"
            item.updatedAt = now
            try item.update(db)
            guard item.kind == "question" || (item.kind == "suggestion" && answer != nil) else { return true }
            let thread = try item.taskID.flatMap { try String.fetchOne(db, sql: "SELECT threadID FROM agent_tasks WHERE id=?", arguments: [$0]) }
            let event = try AgentEventRecord(
                id: UUID.v7().uuidString, sourceID: nil, key: nil, topic: nil,
                note: String(("User response to \(item.title): " + (answer ?? "dismissed without answering")).prefix(Self.noteLimit)),
                ref: Self.text(.object([
                    "item": .string(item.id),
                    "thread_id": thread.map(JSONValue.string) ?? .null,
                    "answer": answer.map(JSONValue.string) ?? .null,
                    "title": .string(item.title),
                    "dismissed": .bool(answer == nil),
                ])),
                occurredAt: now, taskID: item.taskID, handledAt: nil, createdAt: now
            )
            try event.insert(db)
            return true
        }
    }

    func setPaused(_ paused: Bool) throws {
        try dbQueue.write { try AgentAlwaysOnSettingsRecord(paused: paused).save($0) }
    }

    // MARK: - helpers

    private static func process(_ eventIDs: [String], taskID: String?, now: Date = .now, in db: Database) throws {
        for id in eventIDs {
            try db.execute(
                sql: "UPDATE agent_event_inbox SET handledAt=?, taskID=? WHERE id=? AND handledAt IS NULL AND occurredAt<=?",
                arguments: [now, taskID, id, now]
            )
        }
    }

    private static func currentSource(_ id: String, revision: Int, in db: Database) throws -> AgentSourceRecord {
        guard let source = try AgentSourceRecord.fetchOne(db, key: id)
        else { throw Failure(message: "Source not found.") }
        guard source.enabled, source.revision == revision else { throw Failure(message: "Source configuration changed.") }
        return source
    }

    private static func isPaused(in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT paused FROM agent_always_on_settings WHERE id=1") ?? false
    }

    /// Sorted keys keep a stored value byte-for-byte stable.
    private static func text(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try String(decoding: encoder.encode(value), as: UTF8.self)
    }
}
