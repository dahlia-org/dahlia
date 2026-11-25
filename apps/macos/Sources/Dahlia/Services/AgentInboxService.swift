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
        var externalID: String
        var topicKey: String?
        var sender: String?
        var subject: String?
        var excerpt = ""
        var url: String?
        var ref: JSONValue?
        var occurredAt: Date?
        /// Addressed to the user, or mentions them: what a source on `explicit` keeps.
        var direct = false
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

    static let excerptLimit = 500
    static let fieldLimit = 300
    static let refLimit = 4096

    /// Reads the record tool's arguments. They come from the model, which read untrusted mail, so every field is
    /// bounded and a link is kept only when it is an http(s) URL the inbox can safely open.
    static func items(from payload: JSONValue) throws -> [IntakeItem] {
        guard let rows = payload.objectValue?["items"]?.arrayValue else { throw Failure(message: "Pass items as an array.") }
        return try rows.map { row in
            let fields = row.objectValue ?? [:]
            func text(_ key: String, _ limit: Int = fieldLimit) -> String? {
                fields[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map { String($0.prefix(limit)) }
            }
            guard let externalID = text("external_id") else { throw Failure(message: "Every item needs its external_id.") }
            let ref = fields["ref"].flatMap { $0 == .null ? nil : $0 }
            if let ref, try Self.text(ref).utf8.count > refLimit { throw Failure(message: "ref of \(externalID) is too large.") }
            let link = text("url", 2048).flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil }
            return IntakeItem(
                externalID: externalID, topicKey: text("topic_key"), sender: text("sender"), subject: text("subject"),
                excerpt: text("excerpt", excerptLimit) ?? "", url: link?.absoluteString, ref: ref,
                occurredAt: text("occurred_at").flatMap { try? Date($0, strategy: .iso8601) }, direct: fields["direct"] == .bool(true)
            )
        }
    }

    /// The user saw the notice that items may be missing.
    func clearGap(sourceID: String, account: String) throws {
        try dbQueue.write {
            try $0.execute(sql: "UPDATE agent_event_sources SET gapDetectedAt=NULL WHERE id=? AND accountID=?", arguments: [sourceID, account])
        }
    }

    /// Gmail's results carry no link; a thread opens from its ID. Only ID characters are kept, so it stays a Gmail URL.
    static func gmailURL(threadID: String) -> String? {
        let id = threadID.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return id.isEmpty ? nil : "https://mail.google.com/mail/u/0/#all/\(id)"
    }

    /// Enabled Sources whose interval has passed since they last read successfully, oldest first.
    func dueSources(account: String, now: Date = .now) throws -> [AgentSourceRecord] {
        try dbQueue.read { db in
            try AgentSourceRecord.fetchAll(
                db,
                sql: "SELECT * FROM agent_event_sources WHERE accountID=? AND enabled=1 ORDER BY COALESCE(lastIntakeAt, createdAt), id",
                arguments: [account]
            )
        }.filter { ($0.lastIntakeAt ?? .distantPast).addingTimeInterval(Double($0.intervalMinutes) * 60) <= now }
    }

    func sources(account: String) throws -> [AgentSourceRecord] {
        try dbQueue.read {
            try AgentSourceRecord.fetchAll(
                $0,
                sql: "SELECT * FROM agent_event_sources WHERE accountID=? ORDER BY createdAt, id",
                arguments: [account]
            )
        }
    }

    func saveSource(_ source: AgentSourceRecord) throws {
        guard ["explicit", "candidate", "ignore"].contains(source.sieve), source.intervalMinutes >= 5 else {
            throw Failure(message: "A source reads at most every 5 minutes and keeps explicit, candidate, or no items.")
        }
        try dbQueue.write { db in
            var source = source
            if let previous = try AgentSourceRecord.fetchOne(db, key: source.id) {
                guard previous.accountID == source.accountID else { throw Failure(message: "Source belongs to another account.") }
                guard previous.server == source.server, previous.connectionID == source.connectionID else {
                    throw Failure(message: "Create a new Source to use another server.")
                }
                source.revision = previous.revision + 1
                source.cursor = previous.cursor
                source.lastIntakeAt = previous.lastIntakeAt
                source.gapDetectedAt = previous.gapDetectedAt
                source.createdAt = previous.createdAt
            } else {
                source.revision = 1
            }
            try source.save(db)
        }
    }

    /// Deleting a Source removes the events it recorded.
    func deleteSource(id: String, account: String) throws {
        try dbQueue.write {
            try $0.execute(sql: "DELETE FROM agent_event_sources WHERE id=? AND accountID=?", arguments: [id, account])
        }
    }

    /// The newest recorded external events, ignored ones included, for the settings list.
    func recentEvents(account: String, limit: Int = 50) throws -> [AgentEventRecord] {
        try dbQueue.read {
            try AgentEventRecord.fetchAll(
                $0,
                sql: "SELECT * FROM agent_event_inbox WHERE accountID=? AND kind='external' ORDER BY createdAt DESC, id DESC LIMIT ?",
                arguments: [account, limit]
            )
        }
    }

    func isPaused(account: String) throws -> Bool {
        try dbQueue.read { try Self.isPaused(account, in: $0) }
    }

    /// Records what the intake run read. Duplicates keep their first row; the sieve marks the rest ignored or unassigned.
    @discardableResult
    func record(_ items: [IntakeItem], caller: Caller, account: String, now: Date = .now) throws -> [String: String] {
        guard case let .intake(sourceID, revision) = caller else { throw Failure(message: "Only an intake run records items.") }
        return try dbQueue.write { db in
            let source = try Self.currentSource(sourceID, revision: revision, account: account, in: db)
            let allowed = try Set(JSONDecoder().decode([String].self, from: Data(source.allowedSenders.utf8)).map { $0.lowercased() })
            var statuses: [String: String] = [:]
            for item in items {
                let kept = source.sieve != "ignore" && (source.sieve == "candidate" || item.direct)
                    && (allowed.isEmpty || allowed.contains(item.sender?.lowercased() ?? ""))
                let event = try AgentEventRecord(
                    id: UUID.v7().uuidString, accountID: account, kind: "external", sourceID: sourceID,
                    externalID: item.externalID, topicKey: item.topicKey, sender: item.sender, subject: item.subject,
                    excerpt: item.excerpt, url: item.url, ref: item.ref.map(Self.text), occurredAt: item.occurredAt,
                    taskID: nil, payload: "{}", status: kept ? "unassigned" : "ignored", createdAt: now
                )
                try event.insert(db, onConflict: .ignore)
                statuses[item.externalID] = db.changesCount == 1 ? event.status : "duplicate"
            }
            return statuses
        }
    }

    /// Moves the read position only once every item the MCP returned has a row, recorded or ignored.
    /// Returns false, leaving the position, when an item is missing so the next run reads the range again.
    func commitIntake(sourceID: String, revision: Int = 1, account: String, cursor: String?, seen: [String], now: Date = .now) throws -> Bool {
        try dbQueue.write { db in
            var source = try Self.currentSource(sourceID, revision: revision, account: account, in: db)
            for externalID in Set(seen) {
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM agent_event_inbox WHERE accountID=? AND sourceID=? AND externalID=?)",
                    arguments: [account, sourceID, externalID]
                ) ?? false
                if !exists { return false }
            }
            source.cursor = cursor
            source.lastIntakeAt = now
            source.updatedAt = now
            try source.update(db)
            return true
        }
    }

    /// The history the source reads from expired or fell too far behind: the user sees that items may be missing.
    func markGap(sourceID: String, revision: Int = 1, account: String, now: Date = .now) throws {
        try dbQueue.write { db in
            var source = try Self.currentSource(sourceID, revision: revision, account: account, in: db)
            source.gapDetectedAt = now
            try source.update(db)
        }
    }

    // MARK: - Super Agent

    /// The events nobody decided on yet, oldest first, the open Tasks, and the Items the user has not closed: what
    /// `inbox_read` shows Super Agent.
    func inbox(account: String) throws -> (events: [AgentEventRecord], tasks: [AgentTaskRecord], items: [AgentItemRecord]) {
        try dbQueue.read { db in
            try (
                AgentEventRecord.fetchAll(
                    db, sql: "SELECT * FROM agent_event_inbox WHERE accountID=? AND status='unassigned' ORDER BY createdAt, id LIMIT 50",
                    arguments: [account]
                ),
                AgentTaskRecord.fetchAll(
                    db, sql: "SELECT * FROM agent_tasks WHERE accountID=? AND status='active' ORDER BY updatedAt DESC LIMIT 30",
                    arguments: [account]
                ),
                AgentItemRecord.fetchAll(
                    db, sql: "SELECT * FROM agent_user_inbox WHERE accountID=? AND status='open' ORDER BY createdAt DESC LIMIT 30",
                    arguments: [account]
                )
            )
        }
    }

    func hasUndecidedEvents(account: String) throws -> Bool {
        try dbQueue.read {
            try Bool.fetchOne(
                $0,
                sql: "SELECT EXISTS(SELECT 1 FROM agent_event_inbox WHERE accountID=? AND status='unassigned')",
                arguments: [account]
            )
                ?? false
        }
    }

    /// Undecided events by ID, for Super Agent to hand to a thread; an ID that is not one is an error the model sees.
    func undecidedEvents(_ ids: [String], account: String) throws -> [AgentEventRecord] {
        try dbQueue.read { db in
            try ids.map { id in
                guard let event = try AgentEventRecord.fetchOne(db, key: id), event.accountID == account, event.status == "unassigned"
                else { throw Failure(message: "Event \(id) is not waiting for a decision.") }
                return event
            }
        }
    }

    /// Makes a thread Super Agent launched into a Task, and marks the events it was handed as gone to it.
    @discardableResult
    func openTask(threadID: String, title: String, instructions: String, eventIDs: [String], account: String, now: Date = .now) throws
        -> AgentTaskRecord {
        try dbQueue.write {
            try Self.openTask(threadID: threadID, title: title, instructions: instructions, eventIDs: eventIDs, account: account, now: now, in: $0)
        }
    }

    @discardableResult
    static func openTask(
        threadID: String, title: String, instructions: String, eventIDs: [String], account: String, now: Date = .now, in db: Database
    ) throws -> AgentTaskRecord {
        let task = AgentTaskRecord(
            id: UUID.v7().uuidString, accountID: account, title: String(title.prefix(Self.titleLimit)),
            instructions: String(instructions.prefix(Self.bodyLimit)), threadID: threadID, status: "active", createdAt: now, updatedAt: now
        )
        try task.insert(db)
        try Self.process(eventIDs, taskID: task.id, account: account, in: db)
        return task
    }

    /// Super Agent sent more to a Task's thread: the events go to it, and a finished Task is in progress again.
    func continueTask(threadID: String, eventIDs: [String], account: String, now: Date = .now) throws {
        try dbQueue.write { try Self.continueTask(threadID: threadID, eventIDs: eventIDs, account: account, now: now, in: $0) }
    }

    static func continueTask(threadID: String, eventIDs: [String], account: String, now: Date = .now, in db: Database) throws {
        guard let task = try AgentTaskRecord.fetchOne(db, sql: "SELECT * FROM agent_tasks WHERE threadID=? AND accountID=?", arguments: [
            threadID, account,
        ]) else {
            try process(eventIDs, taskID: nil, account: account, in: db)
            return
        }
        try db.execute(sql: "UPDATE agent_tasks SET status='active', updatedAt=? WHERE id=?", arguments: [now, task.id])
        try Self.process(eventIDs, taskID: task.id, account: account, in: db)
    }

    /// Ends a Task, done or dismissed. Its thread stays as it is.
    func finishTask(threadID: String, status: String, account: String, now: Date = .now) throws {
        guard ["done", "dismissed"].contains(status) else { throw Failure(message: "Finish a task as done or dismissed.") }
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE agent_tasks SET status=?, updatedAt=? WHERE threadID=? AND accountID=?", arguments: [status, now, threadID, account]
            )
            guard db.changesCount > 0 else { throw Failure(message: "That thread is not a task.") }
        }
    }

    /// Events that need nothing more: noise, or ones already handled.
    func close(eventIDs: [String], account: String) throws {
        try dbQueue.write { try Self.process(eventIDs, taskID: nil, account: account, in: $0) }
    }

    func task(_ id: String, account: String) throws -> AgentTaskRecord? {
        try dbQueue.read { try AgentTaskRecord.fetchOne($0, key: id).flatMap { $0.accountID == account ? $0 : nil } }
    }

    func task(threadID: String, account: String) throws -> AgentTaskRecord? {
        try dbQueue.read {
            try AgentTaskRecord.fetchOne($0, sql: "SELECT * FROM agent_tasks WHERE threadID=? AND accountID=?", arguments: [threadID, account])
        }
    }

    /// The account's open Tasks, and its finished ones newest first, a page at a time.
    func tasks(account: String, finishedBefore: Date? = nil, limit: Int = 30) throws -> (active: [AgentTaskRecord], finished: [AgentTaskRecord]) {
        try dbQueue.read { db in
            try (
                finishedBefore == nil ? AgentTaskRecord.fetchAll(
                    db, sql: "SELECT * FROM agent_tasks WHERE accountID=? AND status='active' ORDER BY updatedAt DESC, id DESC", arguments: [account]
                ) : [],
                AgentTaskRecord.fetchAll(db, sql: """
                SELECT * FROM agent_tasks WHERE accountID=? AND status<>'active' AND updatedAt<? ORDER BY updatedAt DESC, id DESC LIMIT ?
                """, arguments: [account, finishedBefore ?? .distantFuture, limit])
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

    func items(account: String) throws -> [AgentItemRecord] {
        try dbQueue.read {
            try AgentItemRecord.fetchAll(
                $0, sql: "SELECT * FROM agent_user_inbox WHERE accountID=? AND status='open' ORDER BY createdAt DESC, id DESC",
                arguments: [account]
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
        account: String,
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
                    sql: "SELECT id FROM agent_tasks WHERE threadID=? AND accountID=?",
                    arguments: [thread, account]
                )
                else { throw Failure(message: "That thread is not a task.") }
                return id
            }
            if kind == "suggestion", try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM agent_user_inbox WHERE accountID=? AND kind='suggestion' AND status='dismissed' AND title=? AND updatedAt>=?)",
                arguments: [account, title, now.addingTimeInterval(-Self.dismissalMemory)]
            ) == true {
                throw Failure(message: "The user dismissed this suggestion recently. Do not suggest it again.")
            }
            let item = try AgentItemRecord(
                id: UUID.v7().uuidString, accountID: account, kind: kind, status: "open", taskID: taskID,
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
    func answer(itemID: String, revision: Int, answer: String, account: String, now: Date = .now) throws -> Bool {
        try settle(itemID: itemID, revision: revision, answer: answer, account: account, now: now)
    }

    /// Closes an Item without an answer. A dismissed question still tells Super Agent, so its thread does not wait for it.
    @discardableResult
    func dismiss(itemID: String, revision: Int, account: String, now: Date = .now) throws -> Bool {
        try settle(itemID: itemID, revision: revision, answer: nil, account: account, now: now)
    }

    private func settle(itemID: String, revision: Int, answer: String?, account: String, now: Date) throws -> Bool {
        try dbQueue.write { db in
            guard var item = try AgentItemRecord.fetchOne(db, key: itemID), item.accountID == account, item.status == "open",
                  item.revision == revision else { return false }
            let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map { String($0.prefix(Self.bodyLimit)) }
            item.answer = answer
            item.status = answer != nil || item.kind == "report" ? "done" : "dismissed"
            item.updatedAt = now
            try item.update(db)
            guard item.kind == "question" || (item.kind == "suggestion" && answer != nil) else { return true }
            let thread = try item.taskID.flatMap { try String.fetchOne(db, sql: "SELECT threadID FROM agent_tasks WHERE id=?", arguments: [$0]) }
            let event = try AgentEventRecord(
                id: UUID.v7().uuidString, accountID: account, kind: "answer", sourceID: nil, externalID: nil, topicKey: nil, sender: nil,
                subject: nil, excerpt: answer ?? "", url: nil, ref: nil, occurredAt: nil, taskID: item.taskID,
                payload: Self.text(.object([
                    "item": .string(item.id), "title": .string(item.title), "answer": answer.map(JSONValue.string) ?? .null,
                    "dismissed": .bool(answer == nil), "thread_id": thread.map(JSONValue.string) ?? .null,
                ])),
                status: "unassigned", createdAt: now
            )
            try event.insert(db)
            return true
        }
    }

    func setPaused(_ paused: Bool, account: String) throws {
        try dbQueue.write { try AgentAlwaysOnSettingsRecord(accountID: account, paused: paused).save($0) }
    }

    // MARK: - helpers

    private static func process(_ eventIDs: [String], taskID: String?, account: String, in db: Database) throws {
        for id in eventIDs {
            try db.execute(
                sql: "UPDATE agent_event_inbox SET status='processed', taskID=COALESCE(?, taskID) WHERE id=? AND accountID=? AND status='unassigned'",
                arguments: [taskID, id, account]
            )
        }
    }

    private static func currentSource(_ id: String, revision: Int, account: String, in db: Database) throws -> AgentSourceRecord {
        guard let source = try AgentSourceRecord.fetchOne(db, key: id), source.accountID == account
        else { throw Failure(message: "Source not found.") }
        guard source.enabled, source.revision == revision else { throw Failure(message: "Source configuration changed.") }
        return source
    }

    private static func isPaused(_ account: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT paused FROM agent_always_on_settings WHERE accountID=?", arguments: [account]) ?? false
    }

    /// Sorted keys keep a stored value byte-for-byte stable.
    private static func text(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try String(decoding: encoder.encode(value), as: UTF8.self)
    }
}
