import DahliaRuntimeSupport
import Foundation
import GRDB

/// The agents' inboxes, and the only owner of their event, Task, and Item state. Intake, an agent, and the user reach it
/// only through these methods. The native side sets `Caller` and `agentID` from the Pi session that made the call,
/// never from what the model says it is.
struct AgentInboxService: Sendable {
    enum Caller: Sendable, Equatable {
        case intake(sourceID: String, revision: Int = 1)
    }

    struct IntakeItem: Sendable, Equatable {
        var key: String
        var topic: String?
        var note: String
        var ref: JSONValue?
        /// The link intake saw for the item; kept only when it matches the provider link for this key in this run.
        var url: String?
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
    /// The agent whose sources, events, Tasks, and Items these methods read and write. Methods that name a Source, Task,
    /// or Item by its ID, and the app's housekeeping, use none.
    var agentID = ""

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
                url: text("url"),
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
                sql: "SELECT * FROM agent_event_sources WHERE agentID=? ORDER BY createdAt, id", arguments: [agentID]
            )
        }
    }

    func source(_ id: String) throws -> AgentSourceRecord? {
        try dbQueue.read { try AgentSourceRecord.fetchOne($0, key: id) }
    }

    func hasCalendarSource() throws -> Bool {
        try dbQueue.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM agent_event_sources WHERE kind='calendar')") ?? false }
    }

    func saveSource(_ source: AgentSourceRecord, now: Date = .now) throws {
        guard ["mcp", "calendar"].contains(source.kind), source.intervalMinutes >= 5 else {
            throw Failure(message: "A source reads at most every 5 minutes.")
        }
        if source.kind == "calendar" {
            let options = source.sourceOptions
            guard source.dailyAt != nil || source.leadHours != nil || options.weeklyAt != nil,
                  source.dailyAt.map({ Self.dailyComponents($0) != nil }) ?? true,
                  options.weeklyAt.map({ Self.dailyComponents($0) != nil && (1 ... 7).contains(options.weekday ?? 0) }) ?? true,
                  source.leadHours.map({ $0.isFinite && $0 > 0 && $0 < 168 }) ?? true else {
                throw Failure(message: L10n.agentCalendarInvalidSchedule)
            }
        }
        guard !source.lacksSlackChannels else { throw Failure(message: L10n.agentSlackAllNeedsChannels) }
        try dbQueue.write { db in
            var source = source
            let previous = try AgentSourceRecord.fetchOne(db, key: source.id)
            if let previous {
                guard previous.agentID == source.agentID, previous.kind == source.kind, previous.server == source.server,
                      previous.connectionID == source.connectionID else {
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
                try Self.refreshAgendaNotes(source, in: db)
                // Schedule changes cancel future reservations; arrived agendas remain decisions with their original time.
                if !source.enabled {
                    try db.execute(
                        sql: "DELETE FROM agent_event_inbox WHERE sourceID=? AND handledAt IS NULL AND occurredAt>?",
                        arguments: [source.id, now]
                    )
                } else {
                    if source.dailyAt != previous?.dailyAt {
                        try db.execute(
                            sql: "DELETE FROM agent_event_inbox WHERE sourceID=? AND handledAt IS NULL AND key LIKE 'daily:%' AND occurredAt>?",
                            arguments: [source.id, now]
                        )
                    }
                    let options = source.sourceOptions
                    let previousOptions = previous?.sourceOptions
                    // Only schedule changes invalidate a weekly signal; other edits survive a failed refresh.
                    if options.weeklyAt != previousOptions?.weeklyAt || options.weekday != previousOptions?.weekday {
                        try db.execute(
                            sql: "DELETE FROM agent_event_inbox WHERE sourceID=? AND handledAt IS NULL AND key LIKE 'weekly:%' AND occurredAt>?",
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

    /// Deleting a Source removes the events it recorded and its intake thread.
    func deleteSource(id: String) throws {
        try dbQueue.write {
            try $0.execute(sql: "DELETE FROM chat_threads WHERE id=?", arguments: [id])
            try $0.execute(sql: "DELETE FROM agent_event_sources WHERE id=?", arguments: [id])
        }
    }

    /// The thread a Source's intake runs show in. It has the Source's ID, so it needs no link of its own; it is its agent's,
    /// read-only, and out of the history. Each run starts a new Pi session, so no run sees an earlier one.
    /// The agent whose Source's intake thread this is, if it is one.
    nonisolated static func intakeAgent(threadID: String, in db: any DatabaseReader) -> AgentRecord? {
        try? db.read {
            try AgentRecord.fetchOne(
                $0, sql: "SELECT a.* FROM agents a JOIN agent_event_sources s ON s.agentID=a.id WHERE s.id=?", arguments: [threadID]
            )
        }
    }

    static func intakeThread(_ source: AgentSourceRecord, now: Date, in db: Database) throws -> String {
        let title = "intake-" + AgentHome.directoryName(for: source.name, taken: [])
        if var thread = try ChatThreadRecord.fetchOne(db, key: source.id) {
            if thread.title != title {
                thread.title = title
                try thread.update(db)
            }
        } else {
            try ChatThreadRecord(
                id: source.id, accountID: AppAccount.key, title: title, createdAt: now, updatedAt: now, agentID: source.agentID
            ).insert(db)
        }
        return source.id
    }

    /// The most recently recorded signals for the side panel.
    func recentEvents(limit: Int = 50) throws -> [AgentEventRecord] {
        try dbQueue.read {
            try AgentEventRecord.fetchAll(
                $0,
                sql: "SELECT * FROM agent_event_inbox WHERE agentID=? ORDER BY createdAt DESC, id DESC LIMIT ?",
                arguments: [agentID, limit]
            )
        }
    }

    func isPaused() throws -> Bool {
        try dbQueue.read { try Self.isPaused(in: $0) }
    }

    /// Whether a sender passes the Source's senders and domains; with neither, every sender does.
    nonisolated static func allows(_ sender: String?, senders: Set<String>, domains: [String]) -> Bool {
        let sender = sender?.lowercased() ?? ""
        if senders.isEmpty, domains.isEmpty { return true }
        if senders.contains(sender) { return true }
        guard let at = sender.lastIndex(of: "@") else { return false }
        let domain = sender[sender.index(after: at)...].trimmingCharacters(in: CharacterSet(charactersIn: "> "))
        return domains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// Records selected signals. Duplicates keep their first row; blocked senders leave no row.
    @discardableResult
    func record(
        _ items: [IntakeItem],
        caller: Caller,
        remaining: Int = 20,
        sourceURLs: [String: URL] = [:],
        now: Date = .now
    ) throws -> [String: String] {
        guard case let .intake(sourceID, revision) = caller else { throw Failure(message: "Only an intake run records items.") }
        return try dbQueue.write { db in
            let source = try Self.currentSource(sourceID, revision: revision, in: db)
            let allowed = try Set(JSONDecoder().decode([String].self, from: Data(source.allowedSenders.utf8)).map { $0.lowercased() })
            let domains = source.sourceOptions.allowedDomains ?? []
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
                guard Self.allows(item.sender, senders: allowed, domains: domains) else {
                    statuses[item.key] = "blocked"
                    continue
                }
                guard inserted < min(20, max(0, remaining)) else {
                    statuses[item.key] = "limit"
                    continue
                }
                // The observed link must belong to this item; a supplied hint cannot point to another observed message.
                let url = sourceURLs[item.key].flatMap { item.url == nil || item.url == $0.absoluteString ? $0 : nil }
                let event = try AgentEventRecord(
                    id: UUID.v7().uuidString, agentID: source.agentID, sourceID: sourceID, key: item.key, topic: item.topic,
                    note: String(item.note.prefix(Self.noteLimit)), ref: item.ref.map(Self.text), occurredAt: min(item.occurredAt ?? now, now),
                    taskID: nil, handledAt: nil, createdAt: now, url: url?.absoluteString
                )
                try event.insert(db, onConflict: .ignore)
                if db.changesCount == 1 { inserted += 1 }
                statuses[item.key] = db.changesCount == 1 ? "recorded" : "duplicate"
            }
            return statuses
        }
    }

    /// The range a first read starts from.
    static func intakeFloor(_ now: Date) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-86400))
    }

    /// Pins the bootstrap range before the first read, so caps, failures, and crashes all retry the same lower bound.
    func intakeLowerBound(sourceID: String, revision: Int, now: Date) throws -> String {
        try dbQueue.write { db in
            var source = try Self.currentSource(sourceID, revision: revision, in: db)
            if let cursor = source.cursor { return cursor }
            let lowerBound = Self.intakeFloor(now)
            source.cursor = lowerBound
            try source.update(db)
            return lowerBound
        }
    }

    /// Successful selection need not record every read item. At the cap the next run rereads the pinned range.
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

    // MARK: - The agent

    /// The agent's events nobody decided on yet, oldest first, its open Tasks, and its Items the user has not closed:
    /// what `inbox_read` shows it.
    func inbox(now: Date = .now) throws -> (events: [AgentEventRecord], tasks: [AgentTaskRecord], items: [AgentItemRecord]) {
        try dbQueue.read { db in
            try (
                AgentEventRecord.fetchAll(
                    db, sql: """
                    SELECT * FROM agent_event_inbox WHERE agentID=? AND handledAt IS NULL AND occurredAt<=? ORDER BY occurredAt, id LIMIT 50
                    """, arguments: [agentID, now]
                ),
                AgentTaskRecord.fetchAll(
                    db, sql: "SELECT * FROM agent_tasks WHERE agentID=? AND status='active' ORDER BY updatedAt DESC LIMIT 30",
                    arguments: [agentID]
                ),
                AgentItemRecord.fetchAll(
                    db, sql: "SELECT * FROM agent_user_inbox WHERE agentID=? AND status='open' ORDER BY createdAt DESC LIMIT 30",
                    arguments: [agentID]
                )
            )
        }
    }

    func hasUndecidedEvents(now: Date = .now) throws -> Bool {
        try dbQueue.read {
            try Bool.fetchOne(
                $0,
                sql: "SELECT EXISTS(SELECT 1 FROM agent_event_inbox WHERE agentID=? AND handledAt IS NULL AND occurredAt<=?)",
                arguments: [agentID, now]
            )
                ?? false
        }
    }

    /// The agents with events nobody decided on, for Dahlia to tell each one.
    func agentsWithUndecidedEvents(now: Date = .now) throws -> [String] {
        try dbQueue.read {
            try String.fetchAll($0, sql: """
            SELECT DISTINCT agentID FROM agent_event_inbox WHERE handledAt IS NULL AND occurredAt<=? ORDER BY agentID
            """, arguments: [now])
        }
    }

    /// Topic matches are hints only; the agent decides whether to hand the event to that thread.
    func relatedThreads(for events: [AgentEventRecord]) throws -> [String: [String]] {
        try dbQueue.read { db in
            var result: [String: [String]] = [:]
            for event in events {
                guard let topic = event.topic else { continue }
                result[event.id] = try String.fetchAll(db, sql: """
                SELECT DISTINCT t.threadID FROM agent_tasks t JOIN agent_event_inbox e ON e.taskID=t.id
                WHERE t.agentID=? AND t.status='active' AND t.threadID IS NOT NULL AND e.topic=? AND e.sourceID IS ?
                ORDER BY t.threadID
                """, arguments: [agentID, topic, event.sourceID])
            }
            return result
        }
    }

    /// The agent's undecided events by ID, to hand to a thread; an ID that is not one of them is an error the model sees.
    func undecidedEvents(_ ids: [String]) throws -> [AgentEventRecord] {
        try dbQueue.read { db in
            try ids.map { id in
                guard let event = try AgentEventRecord.fetchOne(db, key: id), event.agentID == agentID, event.handledAt == nil,
                      event.occurredAt <= .now
                else { throw Failure(message: "Event \(id) is not waiting for a decision.") }
                return event
            }
        }
    }

    /// Makes a thread the agent launched into its Task, and marks the events it was handed as gone to it.
    @discardableResult
    func openTask(threadID: String, title: String, instructions: String, eventIDs: [String], now: Date = .now) throws
        -> AgentTaskRecord {
        try dbQueue.write {
            try Self.openTask(
                agentID: agentID, threadID: threadID, title: title, instructions: instructions, eventIDs: eventIDs, now: now, in: $0
            )
        }
    }

    @discardableResult
    static func openTask(
        agentID: String,
        threadID: String,
        title: String,
        instructions: String,
        eventIDs: [String],
        now: Date = .now,
        in db: Database
    ) throws -> AgentTaskRecord {
        let task = AgentTaskRecord(
            id: UUID.v7().uuidString, agentID: agentID, title: String(title.prefix(Self.titleLimit)),
            instructions: String(instructions.prefix(Self.bodyLimit)), threadID: threadID, status: "active", createdAt: now, updatedAt: now
        )
        try task.insert(db)
        try Self.process(eventIDs, agentID: agentID, taskID: task.id, now: now, in: db)
        return task
    }

    /// The agent sent more to one of its Tasks' threads: the events go to it, and a finished Task is in progress again.
    func continueTask(threadID: String, eventIDs: [String], now: Date = .now) throws {
        try dbQueue.write { try Self.continueTask(agentID: agentID, threadID: threadID, eventIDs: eventIDs, now: now, in: $0) }
    }

    static func continueTask(agentID: String, threadID: String, eventIDs: [String], now: Date = .now, in db: Database) throws {
        guard let task = try AgentTaskRecord.fetchOne(
            db, sql: "SELECT * FROM agent_tasks WHERE threadID=? AND agentID=?", arguments: [threadID, agentID]
        ) else {
            try process(eventIDs, agentID: agentID, taskID: nil, now: now, in: db)
            return
        }
        try db.execute(sql: "UPDATE agent_tasks SET status='active', updatedAt=? WHERE id=?", arguments: [now, task.id])
        try Self.process(eventIDs, agentID: agentID, taskID: task.id, now: now, in: db)
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
        guard let task = try task(threadID: threadID), task.agentID == agentID else { throw Failure(message: "That thread is not a task.") }
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
                try db.execute(
                    sql: "UPDATE agent_event_inbox SET handledAt=?, taskID=NULL WHERE id=? AND agentID=? AND handledAt IS NULL",
                    arguments: [Date(), id, agentID]
                )
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

    /// The agent's open Tasks and the visible range of its finished Tasks, in one snapshot.
    func tasks(limit: Int = 30) throws -> (active: [AgentTaskRecord], finished: [AgentTaskRecord]) {
        try dbQueue.read { db in
            try (
                AgentTaskRecord.fetchAll(db, sql: """
                SELECT * FROM agent_tasks WHERE agentID=? AND status='active' ORDER BY updatedAt DESC, id DESC
                """, arguments: [agentID]),
                AgentTaskRecord.fetchAll(db, sql: """
                SELECT * FROM agent_tasks WHERE agentID=? AND status<>'active' ORDER BY updatedAt DESC, id DESC LIMIT ?
                """, arguments: [agentID, limit])
            )
        }
    }

    /// The agent's current thread, made the first time it is needed.
    static func thread(agentID: String, now: Date, in db: Database) throws -> String {
        guard var agent = try AgentRecord.fetchOne(db, key: agentID) else { throw Failure(message: "Agent not found.") }
        if let id = agent.threadID { return id }
        let thread = ChatThreadRecord(
            id: UUID.v7().uuidString, accountID: AppAccount.key, title: agent.name, createdAt: now, updatedAt: now, agentID: agentID
        )
        try thread.insert(db)
        agent.threadID = thread.id
        agent.updatedAt = now
        try agent.update(db)
        return thread.id
    }

    // MARK: - Items

    /// What the side panel shows of one agent's inbox, read in one snapshot so the panel can observe it.
    struct PanelSnapshot: Equatable, Sendable {
        var items: [AgentItemRecord]
        /// Each Task's Thread, by Task, for the Items that belong to one.
        var taskThreads: [String: String]
    }

    func items() throws -> [AgentItemRecord] {
        let agentID = agentID
        return try dbQueue.read { try Self.openItems(agentID: agentID, in: $0) }
    }

    static func openItems(agentID: String, limit: Int = -1, in db: Database) throws -> [AgentItemRecord] {
        try AgentItemRecord.fetchAll(
            db, sql: "SELECT * FROM agent_user_inbox WHERE agentID=? AND status='open' ORDER BY createdAt DESC, id DESC LIMIT ?",
            arguments: [agentID, limit]
        )
    }

    /// Indexed and bounded reads only: with the single-connection fallback, an observation fetches on the writer.
    static func panelSnapshot(agentID: String, limit: Int, in db: Database) throws -> PanelSnapshot {
        let items = try openItems(agentID: agentID, limit: limit, in: db)
        let threads = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
        SELECT id, threadID FROM agent_tasks WHERE threadID IS NOT NULL AND id IN (
            SELECT taskID FROM agent_user_inbox WHERE agentID=? AND status='open'
            ORDER BY createdAt DESC, id DESC LIMIT ?
        )
        """, arguments: [agentID, limit]).map { ($0["id"] as String, $0["threadID"] as String) })
        return PanelSnapshot(items: items, taskThreads: threads)
    }

    /// Each agent's open Item count, for the sidebar's rows.
    static func openItemCounts(in db: Database) throws -> [String: Int] {
        try Dictionary(uniqueKeysWithValues: Row.fetchAll(
            db, sql: """
            SELECT id, (SELECT COUNT(*) FROM agent_user_inbox WHERE agentID=agents.id AND status='open') AS count FROM agents
            """
        ).map { ($0["id"], $0["count"]) })
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
                    sql: "SELECT id FROM agent_tasks WHERE threadID=? AND agentID=?",
                    arguments: [thread, agentID]
                )
                else { throw Failure(message: "That thread is not a task.") }
                return id
            }
            if kind == "suggestion", try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(SELECT 1 FROM agent_user_inbox
                    WHERE agentID=? AND kind='suggestion' AND status='dismissed' AND title=? AND updatedAt>=?)
                """,
                arguments: [agentID, title, now.addingTimeInterval(-Self.dismissalMemory)]
            ) == true {
                throw Failure(message: "The user dismissed this suggestion recently. Do not suggest it again.")
            }
            let item = try AgentItemRecord(
                id: UUID.v7().uuidString, agentID: agentID, kind: kind, status: "open", taskID: taskID,
                title: title, body: String(body.prefix(Self.bodyLimit)), options: Self.text(.array(options.map(JSONValue.string))),
                recommended: recommended.flatMap { options.indices.contains($0) ? $0 : nil }, answer: nil, revision: 1,
                createdAt: now, updatedAt: now
            )
            try item.insert(db)
            return item
        }
    }

    /// The user's answer to the revision they saw. One transaction checks it is still open and current, saves the answer,
    /// and adds the answer event for the Item's agent, so it hears once; an older revision changes nothing.
    @discardableResult
    func answer(itemID: String, revision: Int, answer: String, now: Date = .now) throws -> Bool {
        try settle(itemID: itemID, revision: revision, answer: answer, now: now)
    }

    /// Closes an Item without an answer. A dismissed question still tells its agent, so its thread does not wait for it.
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
                id: UUID.v7().uuidString, agentID: item.agentID, sourceID: nil, key: nil, topic: nil,
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

    private static func process(_ eventIDs: [String], agentID: String, taskID: String?, now: Date = .now, in db: Database) throws {
        for id in eventIDs {
            try db.execute(
                sql: "UPDATE agent_event_inbox SET handledAt=?, taskID=? WHERE id=? AND agentID=? AND handledAt IS NULL AND occurredAt<=?",
                arguments: [now, taskID, id, agentID, now]
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
