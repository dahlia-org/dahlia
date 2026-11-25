import DahliaRuntimeSupport
import Foundation
import GRDB

/// The always-on agent's inbox, and the only owner of its event, task, and action state.
/// intake, the Router, Workers, and the user reach it only through these methods. The native side sets `Caller`
/// from the Pi session that made the call, never from what the model says it is.
struct AgentInboxService: Sendable {
    enum Caller: Sendable, Equatable {
        case intake(sourceID: String, revision: Int = 1)
        case router
        case worker(taskID: String, runID: UUID? = nil)
    }

    enum Authorization: String, Sendable { case allowed, pending, denied }

    enum Decision: Sendable, Equatable {
        case approve(revision: Int)
        case reject
        /// The user's own arguments replace the Worker's; editing approves the new revision.
        case edit(revision: Int, arguments: JSONValue)
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

    struct Routing: Sendable, Equatable {
        var tasksToDeliver: [String]
        var routerNeeded: Bool
    }

    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    static let titleLimit = 140
    static let bodyLimit = 4000
    static let optionLimit = 5
    static let suggestionLifetime: TimeInterval = 3 * 86400
    static let dismissalMemory: TimeInterval = 30 * 86400

    /// A longer string is never treated as an identifier; see `isIdentifier`.
    static let identifierLimit = 256

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

    /// Deleting a Source removes the events it recorded and the topics they were routed by.
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
                    taskID: nil, actionID: nil, payload: "{}", status: kept ? "unassigned" : "ignored", createdAt: now
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

    // MARK: - routing

    /// Chooses each new event's destination by its kind. Only external follow-ups of a topic that an active task owns,
    /// and timers and answers of an active task, go straight to that task's Worker; results, splits, and requests always
    /// go to the Router.
    func route(account: String, now: Date = .now) throws -> Routing {
        try dbQueue.write { db in
            let events = try AgentEventRecord.fetchAll(
                db,
                sql: "SELECT * FROM agent_event_inbox WHERE accountID=? AND status='unassigned' ORDER BY createdAt, id",
                arguments: [account]
            )
            for var event in events {
                switch event.kind {
                case "external":
                    guard let topic = event.topicKey, let source = event.sourceID,
                          let task = try String.fetchOne(db, sql: """
                          SELECT t.id FROM agent_event_topics p JOIN agent_tasks t ON t.id=p.taskID
                          WHERE p.accountID=? AND p.sourceID=? AND p.topicKey=? AND t.status='active'
                          """, arguments: [account, source, topic])
                    else { continue }
                    event.taskID = task
                    event.status = "assigned"
                case "timer", "answer", "request":
                    guard let task = event.taskID, try Self.isActive(task, in: db) else { continue }
                    event.status = "assigned"
                case "decision":
                    let task = try Self.apply(event, account: account, now: now, in: db)
                    // The Worker resumes to run or drop its write; a finished task has no Worker left to tell.
                    if let task, try Self.isActive(task, in: db) {
                        event.taskID = task
                        event.status = "assigned"
                    } else {
                        event.status = "processed"
                    }
                default:
                    continue
                }
                try event.update(db)
            }
            // Suggestions nobody acted on stop crowding the inbox; a dismissal would also block them for 30 days.
            // The events a suggested Task held are let go with it.
            let stale = try AgentItemRecord.fetchAll(
                db, sql: "SELECT * FROM agent_user_inbox WHERE accountID=? AND kind='suggestion' AND status='open' AND createdAt<?",
                arguments: [account, now.addingTimeInterval(-Self.suggestionLifetime)]
            )
            for item in stale {
                try Self.releaseHeld(item, account: account, in: db)
                try item.delete(db)
            }
            let tasks = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT taskID FROM agent_event_inbox WHERE accountID=? AND status='assigned' ORDER BY taskID",
                arguments: [account]
            )
            let router = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM agent_event_inbox WHERE accountID=? AND status='unassigned')",
                arguments: [account]
            ) ?? false
            return Routing(tasksToDeliver: tasks, routerNeeded: router)
        }
    }

    /// The Task ended after these events were routed to it, so the Router decides on them again.
    func returnToRouter(taskID: String, account: String) throws {
        try dbQueue.write {
            try $0.execute(
                sql: "UPDATE agent_event_inbox SET status='unassigned' WHERE accountID=? AND taskID=? AND status IN ('assigned','delivered')",
                arguments: [account, taskID]
            )
        }
    }

    /// After a restart: events no settled run handled go out again, and writes that had started become unknown.
    /// Runs once at launch for every account, before any Worker of this process could have received anything.
    static func recover(in db: Database) throws {
        // Ownerless early-development deliveries are retried; terminal Tasks never retain unresolved input.
        try db.execute(sql: """
        UPDATE agent_event_inbox SET status='unassigned', taskID=NULL, deliveryRunID=NULL
        WHERE status IN ('assigned','delivered') AND taskID IN (SELECT id FROM agent_tasks WHERE status<>'active');
        UPDATE agent_event_inbox SET status='assigned', deliveryRunID=NULL WHERE status='delivered';
        UPDATE agent_worker_deliveries SET status='retry' WHERE status='open';
        """)
        try db.execute(sql: "UPDATE agent_action_outbox SET status='unknown' WHERE status='executing'")
    }

    func recover() throws {
        try dbQueue.write { try Self.recover(in: $0) }
    }

    /// Saves an exact batch and its queued Worker together. A later event remains assigned for the next run.
    func queueWorker(
        taskID: String,
        account: String,
        now: Date = .now,
        input: @Sendable (AgentTaskRecord, [AgentEventRecord]) -> String
    ) throws -> ChatRunRecord? {
        try dbQueue.write { db in
            guard var task = try AgentTaskRecord.fetchOne(db, key: taskID), task.accountID == account, task.status == "active" else { return nil }
            let busy = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM chat_runs WHERE threadID=? AND status IN ('queued','running','waitingForUser'))
                OR EXISTS(SELECT 1 FROM agent_worker_deliveries WHERE taskID=? AND status='open')
            """, arguments: [task.threadID, taskID]) ?? false
            guard !busy else { return nil }
            let events = try AgentEventRecord.fetchAll(db, sql: """
            SELECT * FROM agent_event_inbox WHERE taskID=? AND accountID=? AND status='assigned' ORDER BY createdAt,id
            """, arguments: [taskID, account])
            guard !events.isEmpty else { return nil }
            let threadID = try task.threadID ?? Self.makeThread(for: task, in: db)
            if task.threadID == nil {
                task.threadID = threadID
                try task.update(db)
            }
            let id = UUID.v7()
            var run = ChatRunRecord(
                id: id, threadID: threadID, rootRunID: id, status: "queued", input: input(task, events),
                effort: "medium", approvalMethod: "ask", createdAt: now
            )
            run.origin = "task"
            run.profile = "worker"
            try run.insert(db)
            try AgentWorkerDeliveryRecord(runID: id, accountID: account, taskID: taskID, status: "open").insert(db)
            try db.execute(
                sql: "UPDATE agent_event_inbox SET status='delivered',deliveryRunID=? WHERE taskID=? AND accountID=? AND status='assigned'",
                arguments: [id, taskID, account]
            )
            return run
        }
    }

    /// Only a still-open batch of the active Task may publish Worker effects. Report closes this capability.
    private func withWorker<T>(
        _ caller: Caller, account: String, body: (Database, String, UUID?) throws -> T
    ) throws -> T {
        let taskID = try Self.requireWorker(caller)
        let runID: UUID? = if case let .worker(_, id) = caller { id } else { nil }
        return try dbQueue.write { db in
            guard try Self.isActive(taskID, account: account, in: db) else { throw Failure(message: "This task has finished.") }
            if let runID {
                guard let delivery = try AgentWorkerDeliveryRecord.fetchOne(db, key: runID), delivery.accountID == account,
                      delivery.taskID == taskID, delivery.status == "open" else { throw Failure(message: "This Worker has finished.") }
            } else {
                // Standalone domain operations have no run. Once a Task uses the runtime, its run identity is mandatory.
                let bound = try Bool
                    .fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM agent_worker_deliveries WHERE taskID=?)", arguments: [taskID]) ?? false
                guard !bound else { throw Failure(message: "Identify the Worker run.") }
            }
            return try body(db, taskID, runID)
        }
    }

    /// Runtime settlement never undoes a durable report or cancellation. A failed unacknowledged batch retries.
    func settleWorker(_ run: ChatRunRecord, account: String, succeeded: Bool, summary: String) throws -> Bool {
        let delivery = try dbQueue.read { try AgentWorkerDeliveryRecord.fetchOne($0, key: run.id) }
        guard let delivery, delivery.accountID == account, delivery.status == "open" else { return false }
        if succeeded {
            try addResult(summary: summary, caller: .worker(taskID: delivery.taskID, runID: run.id), account: account)
            return false
        }
        return try withWorker(.worker(taskID: delivery.taskID, runID: run.id), account: account) { db, _, _ in
            try db.execute(
                sql: "UPDATE agent_event_inbox SET status='assigned',deliveryRunID=NULL WHERE deliveryRunID=? AND status='delivered'",
                arguments: [run.id]
            )
            try db.execute(sql: "UPDATE agent_worker_deliveries SET status='retry' WHERE runID=?", arguments: [run.id])
            return true
        }
    }

    // MARK: - Router

    /// `servers` are the MCP servers the Task's Worker may read; the caller keeps them to those the user allowed.
    /// The servers of the Sources its events came from are added, so the Worker can read the originals.
    func createTask(
        title: String,
        instructions: String,
        eventIDs: [String],
        servers: [String] = [],
        caller: Caller,
        account: String,
        now: Date = .now
    ) throws -> AgentTaskRecord {
        try Self.requireRouter(caller)
        return try dbQueue.write { db in
            try Self.openTask(title: title, instructions: instructions, eventIDs: eventIDs, servers: servers, account: account, now: now, in: db)
        }
    }

    /// Opens a Task with its read-only Thread, where its Worker's runs keep their conversation, and assigns the events.
    /// The Router and an accepted suggestion open Tasks through here.
    static func openTask(
        title: String,
        instructions: String,
        eventIDs: [String],
        servers: [String],
        account: String,
        now: Date,
        in db: Database
    ) throws -> AgentTaskRecord {
        let title = String((title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "Task").prefix(titleLimit))
        var task = AgentTaskRecord(
            id: UUID.v7().uuidString, accountID: account, title: title, instructions: instructions, threadID: nil,
            status: "active", createdAt: now, updatedAt: now
        )
        task.workServers = try text(.array(servers.map(JSONValue.string)))
        try task.insert(db)
        try assign(eventIDs, to: task.id, account: account, in: db)
        task.servers = try AgentTaskRecord.fetchOne(db, key: task.id)?.servers ?? task.servers
        task.threadID = try makeThread(for: task, in: db)
        try task.update(db)
        return task
    }

    /// Assigns events to an active task, or moves them there from another task after a split.
    func assign(eventIDs: [String], taskID: String, caller: Caller, account: String) throws {
        try Self.requireRouter(caller)
        try dbQueue.write { db in
            guard try Self.isActive(taskID, account: account, in: db) else { throw Failure(message: "Assign only to an active task.") }
            try Self.assign(eventIDs, to: taskID, account: account, in: db)
        }
    }

    /// The Router read these events and needs nothing more from them: a result it reported, or an item not worth a task.
    func close(eventIDs: [String], caller: Caller, account: String) throws {
        try Self.requireRouter(caller)
        try dbQueue.write { db in
            for id in eventIDs {
                try db.execute(
                    sql: "UPDATE agent_event_inbox SET status='processed' WHERE id=? AND accountID=? AND status='unassigned'",
                    arguments: [id, account]
                )
            }
        }
    }

    /// Ends a task. Writes it had not run yet are dropped so nothing it proposed runs afterwards.
    func finishTask(taskID: String, status: String, caller: Caller, account: String, now: Date = .now) throws {
        try Self.requireRouter(caller)
        guard ["done", "dismissed"].contains(status) else { throw Failure(message: "Finish a task as done or dismissed.") }
        try dbQueue.write { db in
            guard let task = try AgentTaskRecord.fetchOne(db, key: taskID), task.accountID == account else { return }
            try Self.endTask(task, status: status, cancelling: false, now: now, in: db)
        }
    }

    // MARK: - Worker

    /// A Worker's report to the Router. A question for the user rides along; the Router decides whether to ask it.
    func addResult(summary: String, question: String? = nil, options: [String] = [], caller: Caller, account: String, now: Date = .now)
        throws {
        try withWorker(caller, account: account) { db, taskID, runID in
            var event = Self.event(kind: "result", account: account, excerpt: String(summary.prefix(Self.bodyLimit)), taskID: taskID, now: now)
            if let question = question?.nilIfBlank {
                event.payload = try Self.text(.object([
                    "question": .string(String(question.prefix(Self.titleLimit))),
                    "options": .array(options.prefix(Self.optionLimit).map { .string(String($0.prefix(Self.fieldLimit))) }),
                ]))
            }
            event.deliveryRunID = runID
            try event.insert(db)
            if let runID {
                try db.execute(
                    sql: "UPDATE agent_event_inbox SET status='processed' WHERE deliveryRunID=? AND kind<>'result' AND status='delivered'",
                    arguments: [runID]
                )
                try db.execute(
                    sql: "UPDATE agent_worker_deliveries SET status='reported', reportEventID=? WHERE runID=?",
                    arguments: [event.id, runID]
                )
            }
        }
    }

    /// Hands events back to the Router and stops the topic routing more of it to this task.
    func returnEvents(_ eventIDs: [String], caller: Caller, account: String) throws {
        try withWorker(caller, account: account) { db, taskID, runID in
            for id in eventIDs {
                guard let event = try AgentEventRecord.fetchOne(db, key: id), event.accountID == account, event.taskID == taskID,
                      event.kind == "external", event.status == "delivered", runID == nil || event.deliveryRunID == runID else { continue }
                if let source = event.sourceID, let topic = event.topicKey {
                    try db.execute(
                        sql: "DELETE FROM agent_event_topics WHERE accountID=? AND sourceID=? AND topicKey=? AND taskID=?",
                        arguments: [account, source, topic, taskID]
                    )
                }
                try db.execute(sql: "UPDATE agent_event_inbox SET status='unassigned', taskID=NULL, deliveryRunID=NULL WHERE id=?", arguments: [id])
            }
        }
    }

    func setTimer(note: String, dueAt: Date, caller: Caller, account: String, now: Date = .now) throws {
        try withWorker(caller, account: account) { db, taskID, _ in
            try AgentTimerRecord(
                id: UUID.v7().uuidString, accountID: account, taskID: taskID, note: note, dueAt: dueAt, firedAt: nil, createdAt: now
            ).insert(db)
        }
    }

    /// Saves the external write a Worker chose and decides whether it may run. Every write goes through here,
    /// whether a policy allows it or the user approves it later.
    func propose(
        server: String,
        tool: String,
        arguments: JSONValue,
        principal: String,
        caller: Caller,
        account: String,
        now: Date = .now
    ) throws -> (action: AgentActionRecord, authorization: Authorization) {
        try withWorker(caller, account: account) { db, taskID, _ in
            let (authorization, policy) = try Self.authorize(server: server, tool: tool, arguments: arguments, account: account, in: db)
            let status = switch authorization {
            case .allowed: "approved"
            case .pending: "pending"
            case .denied: "denied"
            }
            let action = try AgentActionRecord(
                id: UUID.v7().uuidString, accountID: account, taskID: taskID, revision: 1, server: server, tool: tool,
                arguments: Self.text(arguments), principal: principal, status: status,
                approvedRevision: authorization == .allowed ? 1 : nil, policyID: policy, result: nil, createdAt: now, updatedAt: now
            )
            try action.insert(db)
            return (action, authorization)
        }
    }

    /// Takes the one execution of an allowed write, right before it is sent. Checks again, in the same transaction,
    /// that nothing was paused, revoked, or changed since it was allowed, and returns the arguments to send unchanged.
    func claimExecution(actionID: String, revision: Int, principal: String, caller: Caller, account: String, now: Date = .now) throws
        -> AgentActionRecord {
        try withWorker(caller, account: account) { db, taskID, _ in
            guard var action = try AgentActionRecord.fetchOne(db, key: actionID), action.accountID == account, action.taskID == taskID
            else { throw Failure(message: "Action not found.") }
            guard try !Self.isPaused(account, in: db) else { throw Failure(message: "The always-on agent is paused.") }
            guard action.status == "approved", action.revision == revision, action.approvedRevision == revision else {
                throw Failure(message: "This write is not approved in this revision.")
            }
            guard action.principal == principal else { throw Failure(message: "The account signed in to this server changed.") }
            if let policy = action.policyID {
                let level = try Int.fetchOne(db, sql: "SELECT level FROM agent_action_policies WHERE id=? AND enabled=1", arguments: [policy])
                guard level == 4 else { throw Failure(message: "The policy that allowed this write was revoked.") }
            }
            let disabled = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM agent_event_inbox e JOIN agent_event_sources s ON s.id=e.sourceID WHERE e.taskID=? AND s.enabled=0)
            """, arguments: [taskID]) ?? false
            guard !disabled else { throw Failure(message: "A source of this task is disabled.") }
            action.status = "executing"
            action.updatedAt = now
            try action.update(db)
            return action
        }
    }

    func finishExecution(actionID: String, result: JSONValue, succeeded: Bool, caller: Caller, account: String, now: Date = .now) throws {
        let taskID = try Self.requireWorker(caller)
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE agent_action_outbox SET status=?, result=?, updatedAt=? WHERE id=? AND accountID=? AND taskID=? AND status='executing'",
                arguments: [succeeded ? "succeeded" : "failed", Self.text(result), now, actionID, account, taskID]
            )
        }
    }

    // MARK: - user

    /// The user's answer to a pending write, as an event; routing applies it to the action.
    func decide(_ decision: Decision, actionID: String, account: String, now: Date = .now) throws {
        let payload: JSONValue = switch decision {
        case let .approve(revision): .object(["decision": .string("approve"), "revision": .number(Double(revision))])
        case .reject: .object(["decision": .string("reject")])
        case let .edit(revision, arguments):
            .object(["decision": .string("edit"), "revision": .number(Double(revision)), "arguments": arguments])
        }
        try dbQueue.write { db in
            var event = try Self.event(kind: "decision", account: account, excerpt: "", taskID: nil, now: now)
            event.actionID = actionID
            event.payload = try Self.text(payload)
            try event.insert(db)
        }
    }

    /// The user says these events do not belong where they are; the Router assigns them again.
    func split(_ eventIDs: [String], account: String, now: Date = .now) throws {
        try dbQueue.write { db in
            var event = try Self.event(kind: "split", account: account, excerpt: "", taskID: nil, now: now)
            event.payload = try Self.text(.object(["events": .array(eventIDs.map(JSONValue.string))]))
            try event.insert(db)
        }
    }

    /// Something the user asks the secretary to do, from the inbox or the Home thread. The Router opens a Task for it;
    /// a request for an open Task goes straight to that Task's Worker.
    func request(_ text: String, taskID: String? = nil, account: String, now: Date = .now) throws {
        guard let text = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else { throw Failure(message: "Write the request.") }
        let event = Self.event(kind: "request", account: account, excerpt: String(text.prefix(Self.bodyLimit)), taskID: nil, now: now)
        try dbQueue.write { db in
            var event = event
            if let taskID {
                guard try Self.isActive(taskID, account: account, in: db) else { throw Failure(message: "That task is not open.") }
                event.taskID = taskID
            }
            try event.insert(db)
        }
    }

    func items(account: String) throws -> [AgentItemRecord] {
        try dbQueue.read {
            try AgentItemRecord.fetchAll(
                $0, sql: "SELECT * FROM agent_user_inbox WHERE accountID=? AND status='open' ORDER BY createdAt DESC, id DESC",
                arguments: [account]
            )
        }
    }

    /// The user's answer to the revision they saw. One transaction checks it is still open and current, saves the answer,
    /// and adds the answer event for the Task that asked, so the Worker resumes once; an older revision changes nothing.
    @discardableResult
    func answer(itemID: String, revision: Int, answer: String, account: String, now: Date = .now) throws -> Bool {
        try settle(itemID: itemID, revision: revision, answer: answer, account: account, now: now)
    }

    /// Closes an Item without an answer. A dismissed question still tells its Task, so the Worker does not wait for it.
    @discardableResult
    func dismiss(itemID: String, revision: Int, account: String, now: Date = .now) throws -> Bool {
        try settle(itemID: itemID, revision: revision, answer: nil, account: account, now: now)
    }

    private func settle(itemID: String, revision: Int, answer: String?, account: String, now: Date) throws -> Bool {
        try dbQueue.write { db in
            guard var item = try AgentItemRecord.fetchOne(db, key: itemID), item.accountID == account, item.status == "open",
                  item.revision == revision, item.kind != "approval" else { return false }
            let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map { String($0.prefix(Self.bodyLimit)) }
            item.answer = answer
            item.status = answer != nil || item.kind == "report" ? "done" : "dismissed"
            item.updatedAt = now
            try item.update(db)
            if let proposal = try item.proposal.map({ try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)).objectValue ?? [:] }) {
                guard answer != nil else {
                    try Self.releaseHeld(item, account: account, in: db)
                    return true
                }
                func list(_ key: String) -> [String] { proposal[key]?.arrayValue?.compactMap(\.stringValue) ?? [] }
                let held = try list("event_ids").filter {
                    try AgentEventRecord.fetchOne(db, key: $0).map { $0.accountID == account && $0.status == "held" } ?? false
                }
                _ = try Self.openTask(
                    title: proposal["title"]?.stringValue ?? item.title, instructions: proposal["instructions"]?.stringValue ?? "",
                    eventIDs: held, servers: list("servers"), account: account, now: now, in: db
                )
                return true
            }
            guard item.kind == "question" || (item.kind == "suggestion" && answer != nil) else { return true }
            var event = Self.event(kind: "answer", account: account, excerpt: answer ?? "", taskID: item.taskID, now: now)
            event.payload = try Self.text(.object([
                "item": .string(item.id), "title": .string(item.title), "answer": answer.map(JSONValue.string) ?? .null,
                "dismissed": .bool(answer == nil),
            ]))
            try event.insert(db)
            return true
        }
    }

    func setPolicy(server: String, tool: String, conditions: [String: JSONValue], level: Int, account: String, now: Date = .now) throws
        -> AgentPolicyRecord {
        guard (1 ... 4).contains(level) else { throw Failure(message: "Levels run from 1 to 4.") }
        let policy = try AgentPolicyRecord(
            id: UUID.v7().uuidString, accountID: account, server: server, tool: tool, conditions: Self.text(.object(conditions)),
            level: level, enabled: true, createdAt: now, updatedAt: now
        )
        try dbQueue.write { try policy.insert($0) }
        return policy
    }

    func revokePolicy(id: String, account: String, now: Date = .now) throws {
        try dbQueue.write {
            try $0.execute(sql: "UPDATE agent_action_policies SET enabled=0, updatedAt=? WHERE id=? AND accountID=?", arguments: [now, id, account])
        }
    }

    func setPaused(_ paused: Bool, account: String) throws {
        try dbQueue.write { try AgentAlwaysOnSettingsRecord(accountID: account, paused: paused).save($0) }
    }

    // MARK: - Router's Items

    /// Shows the user a question, a report, or a suggestion. Only the Router makes Items; Workers report through results.
    /// A suggestion the user dismissed in the last 30 days is not made again.
    @discardableResult
    func createItem(
        kind: String,
        title: String,
        body: String = "",
        options: [String] = [],
        recommended: Int? = nil,
        taskID: String? = nil,
        caller: Caller,
        account: String,
        now: Date = .now
    ) throws -> AgentItemRecord {
        try Self.requireRouter(caller)
        guard ["question", "report", "suggestion"].contains(kind) else { throw Failure(message: "Make a question, report, or suggestion.") }
        guard let title = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map({ String($0.prefix(Self.titleLimit)) })
        else { throw Failure(message: "An Item needs a title.") }
        let options = Array(options.compactMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank.map { String($0.prefix(Self.fieldLimit)) }
        }.prefix(Self.optionLimit))
        return try dbQueue.write { db in
            if let taskID, try !Self.isActive(taskID, account: account, in: db) { throw Failure(message: "Task not found.") }
            if kind == "suggestion", try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM agent_user_inbox WHERE accountID=? AND kind='suggestion' AND status='dismissed' AND title=? AND updatedAt>=?)",
                arguments: [account, title, now.addingTimeInterval(-Self.dismissalMemory)]
            ) == true {
                throw Failure(message: "The user dismissed this suggestion recently. Do not suggest it again.")
            }
            let item = try AgentItemRecord(
                id: UUID.v7().uuidString, accountID: account, kind: kind, status: "open", taskID: taskID, actionID: nil,
                title: title, body: String(body.prefix(Self.bodyLimit)), options: Self.text(.array(options.map(JSONValue.string))),
                recommended: recommended.flatMap { options.indices.contains($0) ? $0 : nil }, answer: nil, revision: 1,
                proposal: nil, createdAt: now, updatedAt: now
            )
            try item.insert(db)
            return item
        }
    }

    /// Work the user did not ask for starts as a suggestion: its events are held until the user accepts, which opens the
    /// Task, or dismisses, which lets them go. A secretary asks before taking on something new.
    @discardableResult
    func suggestTask(
        title: String,
        instructions: String,
        body: String = "",
        eventIDs: [String],
        servers: [String] = [],
        caller: Caller,
        account: String,
        now: Date = .now
    ) throws -> AgentItemRecord {
        var item = try createItem(kind: "suggestion", title: title, body: body, caller: caller, account: account, now: now)
        try dbQueue.write { db in
            for id in eventIDs {
                try db.execute(
                    sql: "UPDATE agent_event_inbox SET status='held' WHERE id=? AND accountID=? AND status='unassigned' AND kind IN ('external','timer')",
                    arguments: [id, account]
                )
            }
            item.proposal = try Self.text(.object([
                "title": .string(item.title), "instructions": .string(String(instructions.prefix(Self.bodyLimit))),
                "event_ids": .array(eventIDs.map(JSONValue.string)), "servers": .array(servers.map(JSONValue.string)),
            ]))
            try item.update(db)
        }
        return item
    }

    /// A Task's Thread, under the secretary's Home thread as the threads a chat starts sit under it, so tasks do not crowd
    /// the sidebar.
    private static func makeThread(for task: AgentTaskRecord, in db: Database) throws -> String {
        var thread = ChatThreadRecord(id: UUID.v7().uuidString, accountID: task.accountID, title: task.title, createdAt: .now, updatedAt: .now)
        thread.parentThreadID = try homeThread(account: task.accountID, now: .now, in: db)
        try thread.insert(db)
        return thread.id
    }

    /// The Thread a Worker run goes to. A Task whose Thread the user deleted gets a new one, so its work goes on.
    func thread(for task: AgentTaskRecord) throws -> String {
        try dbQueue.write { db in
            if let id = task.threadID, try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chat_threads WHERE id=?)", arguments: [id]) == true {
                return id
            }
            var task = task
            task.threadID = try Self.makeThread(for: task, in: db)
            try task.update(db)
            return task.threadID!
        }
    }

    /// The account's Home thread, made when the first Task needs a place.
    static func homeThread(account: String, now: Date, in db: Database) throws -> String {
        let key = AgentBotSettings.homeThreadKey(accountKey: account)
        if let id = UserDefaults.standard.string(forKey: key),
           try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chat_threads WHERE id=? AND accountID=?)", arguments: [id, account]) == true {
            return id
        }
        let thread = ChatThreadRecord(id: UUID.v7().uuidString, accountID: account, title: L10n.agentBotHome, createdAt: now, updatedAt: now)
        try thread.insert(db)
        UserDefaults.standard.set(thread.id, forKey: key)
        return thread.id
    }

    private static func releaseHeld(_ item: AgentItemRecord, account: String, in db: Database) throws {
        let proposal = try item.proposal.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)).objectValue ?? [:] } ?? [:]
        for id in proposal["event_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            try db.execute(
                sql: "UPDATE agent_event_inbox SET status='processed' WHERE id=? AND accountID=? AND status='held'", arguments: [id, account]
            )
        }
    }

    func task(threadID: String, account: String) throws -> AgentTaskRecord? {
        try dbQueue.read {
            try AgentTaskRecord.fetchOne($0, sql: "SELECT * FROM agent_tasks WHERE threadID=? AND accountID=?", arguments: [threadID, account])
        }
    }

    /// Tasks whose Thread has no Worker run queued or running, so a new delivery can start one.
    func idleTasks(_ taskIDs: [String], account: String) throws -> [AgentTaskRecord] {
        try dbQueue.read { db in
            try taskIDs.compactMap { id in
                try AgentTaskRecord.fetchOne(db, sql: """
                SELECT t.* FROM agent_tasks t WHERE t.id=? AND t.accountID=? AND t.status='active'
                AND NOT EXISTS(SELECT 1 FROM chat_runs r WHERE r.threadID=t.threadID AND r.status IN ('queued','running','waitingForUser'))
                """, arguments: [id, account])
            }
        }
    }

    /// What one Router run decides on: the events nobody owns yet, the open Tasks, and the Items the user has not closed.
    func routerInput(account: String) throws -> (events: [AgentEventRecord], tasks: [AgentTaskRecord], items: [AgentItemRecord]) {
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

    func task(_ id: String, account: String) throws -> AgentTaskRecord? {
        try dbQueue.read { try AgentTaskRecord.fetchOne($0, key: id).flatMap { $0.accountID == account ? $0 : nil } }
    }

    // MARK: - timers

    func fireTimers(account: String, now: Date = .now) throws {
        try dbQueue.write { db in
            let due = try AgentTimerRecord.fetchAll(
                db,
                sql: "SELECT * FROM agent_timers WHERE accountID=? AND firedAt IS NULL AND dueAt<=? ORDER BY dueAt, id",
                arguments: [account, now]
            )
            for var timer in due {
                try Self.event(kind: "timer", account: account, excerpt: timer.note, taskID: timer.taskID, now: now).insert(db)
                timer.firedAt = now
                try timer.update(db)
            }
        }
    }

    // MARK: - authorization

    /// Restrictive first: any matching policy at level 1 or 2 denies; level 4 allows only identifier-like arguments
    /// beyond the ones it fixes; everything else waits for the user.
    static func authorize(server: String, tool: String, arguments: JSONValue, account: String, in db: Database) throws
        -> (Authorization, String?) {
        let args = arguments.objectValue ?? [:]
        let policies = try AgentPolicyRecord.fetchAll(
            db,
            sql: "SELECT * FROM agent_action_policies WHERE accountID=? AND server=? AND tool=? AND enabled=1 ORDER BY level, createdAt, id",
            arguments: [account, server, tool]
        )
        let matching = try policies.filter { policy in
            let conditions = try JSONDecoder().decode(JSONValue.self, from: Data(policy.conditions.utf8)).objectValue ?? [:]
            return conditions.allSatisfy { args[$0.key] == $0.value }
        }
        if matching.contains(where: { $0.level <= 2 }) { return (.denied, nil) }
        for policy in matching where policy.level == 4 {
            let fixed = try Set((JSONDecoder().decode(JSONValue.self, from: Data(policy.conditions.utf8)).objectValue ?? [:]).keys)
            if args.filter({ !fixed.contains($0.key) }).values.allSatisfy(isIdentifier) { return (.allowed, policy.id) }
        }
        return (.pending, nil)
    }

    /// shortcut: free text is told apart by shape (ASCII identifier characters only), so prose in any language,
    /// including Japanese without spaces, needs approval. Replace with per-tool argument roles once Sources declare them.
    static func isIdentifier(_ value: JSONValue) -> Bool {
        switch value {
        case let .string(text):
            text.count <= identifierLimit && text.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._:@/+=#-_".unicodeScalars.contains($0))
            }
        case let .array(values): values.allSatisfy(isIdentifier)
        case let .object(values): values.values.allSatisfy(isIdentifier)
        case .number, .bool, .null: true
        }
    }

    // MARK: - helpers

    private static func apply(_ event: AgentEventRecord, account: String, now: Date, in db: Database) throws -> String? {
        guard let id = event.actionID, var action = try AgentActionRecord.fetchOne(db, key: id), action.accountID == account
        else { return nil }
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(event.payload.utf8)).objectValue ?? [:]
        // An answer to a revision the user no longer sees, or to a write that already settled, changes nothing.
        guard action.status == "pending" else { return action.taskID }
        switch payload["decision"]?.stringValue {
        case "approve" where payload["revision"]?.intValue == action.revision:
            action.status = "approved"
            action.approvedRevision = action.revision
        case "edit" where payload["revision"]?.intValue == action.revision:
            action.revision += 1
            action.arguments = try text(payload["arguments"] ?? .object([:]))
            action.status = "approved"
            action.approvedRevision = action.revision
        case "reject":
            action.status = "rejected"
        default:
            return action.taskID
        }
        action.updatedAt = now
        try action.update(db)
        return action.taskID
    }

    private static func assign(_ eventIDs: [String], to taskID: String, account: String, in db: Database) throws {
        for id in eventIDs {
            guard var event = try AgentEventRecord.fetchOne(db, key: id), event.accountID == account, event.status != "ignored",
                  ["external", "timer", "request", "answer"].contains(event.kind) else { throw Failure(message: "Event \(id) cannot be assigned.") }
            if let source = event.sourceID, let topic = event.topicKey {
                try AgentTopicRecord(accountID: account, sourceID: source, topicKey: topic, taskID: taskID).save(db)
            }
            event.taskID = taskID
            event.status = "assigned"
            try event.update(db)
        }
        guard var task = try AgentTaskRecord.fetchOne(db, key: taskID), task.accountID == account else {
            throw Failure(message: "Task not found.")
        }
        let previous = try JSONDecoder().decode([String].self, from: Data(task.servers.utf8))
        let sources = try String.fetchAll(db, sql: """
        SELECT DISTINCT s.connectionID FROM agent_event_inbox e JOIN agent_event_sources s ON s.id=e.sourceID WHERE e.taskID=? AND s.connectionID<>''
        """, arguments: [taskID])
        task.servers = try text(.array(Array(Set(previous + sources)).sorted().map(JSONValue.string)))
        try task.update(db)
    }

    /// Explicit stop cancels the Task as well as its run, so durable deliveries cannot restart it later.
    static func stopWorker(runID: UUID, in db: Database) throws {
        guard let run = try ChatRunRecord.fetchOne(db, key: runID), run.origin == "task",
              ["queued", "running", "waitingForUser"].contains(run.status),
              let task = try AgentTaskRecord.fetchOne(db, sql: "SELECT * FROM agent_tasks WHERE threadID=?", arguments: [run.threadID]),
              task.status == "active" else { return }
        try endTask(task, status: "dismissed", cancelling: true, now: .now, in: db)
    }

    /// Completion returns work the Worker has not received; explicit cancellation consumes it instead.
    private static func endTask(_ task: AgentTaskRecord, status: String, cancelling: Bool, now: Date, in db: Database) throws {
        try db.execute(sql: "UPDATE agent_tasks SET status=?, updatedAt=? WHERE id=?", arguments: [status, now, task.id])
        try db.execute(sql: "DELETE FROM agent_timers WHERE taskID=? AND firedAt IS NULL", arguments: [task.id])
        if cancelling {
            try db.execute(
                sql: "UPDATE agent_event_inbox SET status='processed' WHERE taskID=? AND status IN ('assigned','delivered')",
                arguments: [task.id]
            )
        } else {
            try db.execute(
                sql: "UPDATE agent_event_inbox SET status='unassigned', taskID=NULL, deliveryRunID=NULL WHERE taskID=? AND status IN ('assigned','delivered')",
                arguments: [task.id]
            )
        }
        try db.execute(
            sql: "UPDATE agent_worker_deliveries SET status=? WHERE taskID=? AND status='open'",
            arguments: [cancelling ? "cancelled" : "returned", task.id]
        )
        try db.execute(
            sql: "UPDATE chat_runs SET status='interrupted' WHERE threadID=? AND origin='task' AND status='queued'",
            arguments: [task.threadID]
        )
        try db.execute(
            sql: "UPDATE agent_action_outbox SET status='rejected', updatedAt=? WHERE taskID=? AND status IN ('pending','approved')",
            arguments: [now, task.id]
        )
    }

    private static func currentSource(_ id: String, revision: Int, account: String, in db: Database) throws -> AgentSourceRecord {
        let source = try source(id, account: account, in: db)
        guard source.enabled, source.revision == revision else { throw Failure(message: "Source configuration changed.") }
        return source
    }

    private static func event(kind: String, account: String, excerpt: String, taskID: String?, now: Date) -> AgentEventRecord {
        AgentEventRecord(
            id: UUID.v7().uuidString, accountID: account, kind: kind, sourceID: nil, externalID: nil, topicKey: nil, sender: nil,
            subject: nil, excerpt: excerpt, url: nil, ref: nil, occurredAt: nil, taskID: taskID, actionID: nil, payload: "{}",
            status: "unassigned", createdAt: now
        )
    }

    private static func source(_ id: String, account: String, in db: Database) throws -> AgentSourceRecord {
        guard let source = try AgentSourceRecord.fetchOne(db, key: id), source.accountID == account
        else { throw Failure(message: "Source not found.") }
        return source
    }

    private static func isActive(_ taskID: String, account: String? = nil, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM agent_tasks WHERE id=? AND status='active' AND (? IS NULL OR accountID=?))",
            arguments: [taskID, account, account]
        ) ?? false
    }

    private static func isPaused(_ account: String, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT paused FROM agent_always_on_settings WHERE accountID=?", arguments: [account]) ?? false
    }

    private static func requireRouter(_ caller: Caller) throws {
        guard caller == .router else { throw Failure(message: "Only the Router assigns events and opens or finishes tasks.") }
    }

    private static func requireWorker(_ caller: Caller) throws -> String {
        guard case let .worker(taskID, _) = caller else { throw Failure(message: "Only a task's Worker can do this.") }
        return taskID
    }

    /// Sorted keys keep a stored value byte-for-byte stable, so the arguments sent are the ones saved.
    private static func text(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try String(decoding: encoder.encode(value), as: UTF8.self)
    }
}
