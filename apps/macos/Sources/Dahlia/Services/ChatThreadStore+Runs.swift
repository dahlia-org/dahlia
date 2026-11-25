import DahliaRuntimeSupport
import Foundation
import GRDB

extension ChatThreadStore {
    static let resultExcerptLimit = 1200

    /// Kept apart from the status, which the run's own end overwrites.
    func markStoppedByUser(_ id: UUID) throws {
        try dbQueue.write {
            try $0.execute(sql: """
            UPDATE chat_runs SET stoppedByUser=1 WHERE id=? OR id IN (
                SELECT r.rootRunID FROM chat_runs r JOIN chat_runs root ON root.id=r.rootRunID
                WHERE r.id=? AND root.threadID=r.threadID
            )
            """, arguments: [id, id])
        }
    }

    func interruptQueuedRun(_ id: UUID) throws {
        try dbQueue.write {
            try $0.execute(sql: "UPDATE chat_runs SET status = 'interrupted' WHERE id = ? AND status = 'queued'", arguments: [id])
        }
    }

    /// Additional local handoff state commits with the run and retry key, and never repeats on a duplicate.
    func enqueueRun(_ run: ChatRunRecord, budget: Int = 12, updating: @Sendable (Database) throws -> Void = { _ in }) throws -> ChatRunRecord {
        var run = run
        if run.rootRunID != run.id { run.origin = "thread" }
        return try dbQueue.write { db in
            guard let target = try ChatThreadRecord.fetchOne(db, key: run.threadID) else {
                throw PiRuntimeError.invalidProtocolResponse
            }
            if let requesterID = run.requestedByThreadID {
                guard let requester = try ChatThreadRecord.fetchOne(db, key: requesterID),
                      requester.accountID == target.accountID, requester.parentThreadID == nil,
                      requesterID != target.id else { throw PiRuntimeError.invalidProtocolResponse }
                if let key = run.clientRequestID,
                   let existing = try ChatRunRecord.fetchOne(
                       db,
                       sql: "SELECT * FROM chat_runs WHERE requestedByThreadID = ? AND rootRunID = ? AND clientRequestID = ?",
                       arguments: [requesterID, run.rootRunID, key]
                   ) {
                    return existing
                }
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_runs WHERE rootRunID = ?", arguments: [run.rootRunID]) ?? 0
                guard count < budget else { throw PiRuntimeError.rpcError(code: nil, message: "Thread run budget exhausted") }
            }
            try run.insert(db)
            try updating(db)
            guard let saved = try ChatRunRecord.fetchOne(db, key: run.id) else { throw PiRuntimeError.invalidProtocolResponse }
            return saved
        }
    }

    /// Preparation belongs to one saved route. Reset may move its thread or requester while Pi starts.
    func claimQueuedRun(_ expected: ChatRunRecord, input: String? = nil) throws -> ChatRunRecord? {
        try transitionQueuedRun(expected, status: "running", input: input)
    }

    func failQueuedRun(_ expected: ChatRunRecord) throws -> ChatRunRecord? {
        try transitionQueuedRun(expected, status: "failed")
    }

    private func transitionQueuedRun(_ expected: ChatRunRecord, status: String, input: String? = nil) throws -> ChatRunRecord? {
        try dbQueue.write { db in
            let transitioned = try ChatRunRecord.fetchOne(db, sql: """
            UPDATE chat_runs SET status=?, input=?,
                startedAt=CASE WHEN ?='running' THEN COALESCE(startedAt, ?) ELSE startedAt END,
                completedAt=CASE WHEN ?='failed' THEN COALESCE(completedAt, ?) ELSE completedAt END
            WHERE id=? AND status='queued' AND threadID=? AND requestedByThreadID IS ?
            RETURNING *
            """, arguments: [
                status,
                status == "running" ? (input ?? expected.input) : "",
                status,
                Date(),
                status,
                Date(),
                expected.id,
                expected.threadID,
                expected.requestedByThreadID,
            ])
            // RETURNING precedes AFTER triggers; publish their saved start order too.
            return try transitioned.flatMap { try ChatRunRecord.fetchOne(db, key: $0.id) }
        }
    }

    func appendRecoveryInputs(_ inputs: [CodexAppServerInput], runID: UUID) throws {
        try dbQueue.write { db in
            guard let run = try ChatRunRecord.fetchOne(db, key: runID), ["running", "waitingForUser"].contains(run.status),
                  !run.input.isEmpty else { return }
            let previous = try ChatHistoryCodec.decodeInputs(run.input)
            let saved = try ChatHistoryCodec.encodeInputs(previous + [.text("Additional instruction during this turn:")] + inputs)
            try db.execute(sql: "UPDATE chat_runs SET input=? WHERE id=?", arguments: [saved, runID])
        }
    }

    /// A failed steer may or may not have reached Pi; the agreed input can no longer be reconstructed safely.
    func invalidateRecoveryInput(_ runID: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE chat_runs SET input='' WHERE id=?", arguments: [runID])
        }
    }

    func appendRunResponse(_ run: ChatRunRecord, items: [JSONValue], text: String) throws {
        try dbQueue.write { db in
            try Self.append(items, threadID: run.threadID, runID: run.id, in: db)
            if !text.isEmpty {
                try db.execute(
                    sql: "UPDATE chat_runs SET resultExcerpt = ? WHERE id = ?",
                    arguments: [String(text.prefix(run.origin == "schedule" ? 8000 : Self.resultExcerptLimit)), run.id]
                )
            }
            if run.origin == "schedule", !text.isEmpty {
                try db.execute(sql: "UPDATE chat_schedule_fires SET resultKind=? WHERE runID=?", arguments: [AgentSchedule.result(text), run.id])
            }
            try db.execute(sql: "UPDATE chat_threads SET updatedAt = ? WHERE id = ?", arguments: [Date(), run.threadID])
        }
    }

    func activeRunAccounts() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
            SELECT DISTINCT t.accountID FROM chat_runs r JOIN chat_threads t ON t.id = r.threadID
            WHERE r.status IN ('queued', 'running', 'waitingForUser')
            """)
        }
    }

    /// Stopping a whole account also covers results that settled but were not delivered yet, so none restarts a parent later.
    func suppressRunNotifications(accountID: String, threadID: String? = nil) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
            UPDATE chat_runs SET suppressAutomaticNotification = 1
            WHERE (status IN ('queued', 'running', 'waitingForUser') OR (? IS NULL AND resultDeliveredAt IS NULL))
                AND threadID IN (SELECT id FROM chat_threads WHERE accountID = ?)
                AND (? IS NULL OR threadID = ?)
            """, arguments: [threadID, accountID, threadID, threadID])
        }
    }

    func setRunStatus(_ id: UUID, status: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE chat_runs SET input = CASE WHEN ? IN ('completed', 'failed', 'interrupted') THEN '' ELSE input END, status = ?,
                    startedAt = CASE WHEN ? = 'running' THEN COALESCE(startedAt, ?) ELSE startedAt END,
                    completedAt = CASE WHEN ? IN ('completed', 'failed', 'interrupted') THEN COALESCE(completedAt, ?) ELSE completedAt END,
                    resultDeliveredAt = CASE WHEN ? IN ('completed', 'failed', 'interrupted') THEN NULL ELSE resultDeliveredAt END
                WHERE id = ?
                """,
                arguments: [status, status, status, Date(), status, Date(), status, id]
            )
        }
    }

    func run(id: UUID) throws -> ChatRunRecord? {
        try dbQueue.read {
            try ChatRunRecord.fetchOne($0, key: id)
        }
    }

    func interruptQueuedRuns(accountID: String, threadID: String? = nil, preservingSchedules: Bool = false) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
            UPDATE chat_runs SET status = 'interrupted' WHERE status = 'queued'
                AND threadID IN (SELECT id FROM chat_threads WHERE accountID = ?)
                AND (? IS NULL OR threadID = ?) AND (?=0 OR origin <> 'schedule')
            """, arguments: [accountID, threadID, threadID, preservingSchedules])
        }
    }

    /// Started turns keep execution order; untouched work follows in acceptance order, then attempts.
    static func runOrderSQL(descending: Bool = false) -> String {
        let direction = descending ? "DESC" : "ASC"
        return "(executionSequence IS NULL) \(direction), executionSequence \(direction), logicalSequence \(direction), rowid \(direction)"
    }

    func queuedRuns(accountID: String) throws -> [ChatRunRecord] {
        try dbQueue.read { db in
            try ChatRunRecord.fetchAll(db, sql: """
            SELECT * FROM chat_runs WHERE threadID IN (SELECT id FROM chat_threads WHERE accountID=?) AND status='queued'
            ORDER BY \(Self.runOrderSQL()) LIMIT 100
            """, arguments: [accountID])
        }
    }

    func undeliveredRuns(requesterID: String) throws -> [ChatRunRecord] {
        try dbQueue.read { db in
            try ChatRunRecord.fetchAll(db, sql: """
            SELECT * FROM chat_runs WHERE requestedByThreadID = ? AND resultDeliveredAt IS NULL
                AND status IN ('completed', 'interrupted', 'failed', 'waitingForUser')
            ORDER BY \(Self.runOrderSQL()) LIMIT 100
            """, arguments: [requesterID])
        }
    }

    func markRunsDelivered(_ runs: [ChatRunRecord]) throws {
        try dbQueue.write { db in
            for run in runs {
                try db.execute(
                    sql: "UPDATE chat_runs SET resultDeliveredAt = ? WHERE id = ? AND resultDeliveredAt IS NULL",
                    arguments: [Date(), run.id]
                )
            }
        }
    }

}
