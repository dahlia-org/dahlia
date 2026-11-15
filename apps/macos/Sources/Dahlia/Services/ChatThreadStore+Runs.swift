import DahliaRuntimeSupport
import Foundation
import GRDB

extension ChatThreadStore {
    static let resultExcerptLimit = 1200

    /// Kept apart from the status, which the run's own end overwrites.
    func markStoppedByUser(_ id: UUID) throws {
        try dbQueue.write {
            try $0.execute(sql: "UPDATE chat_runs SET stoppedByUser = 1 WHERE id = ?", arguments: [id])
        }
    }

    func interruptQueuedRun(_ id: UUID) throws {
        try dbQueue.write {
            try $0.execute(sql: "UPDATE chat_runs SET status = 'interrupted' WHERE id = ? AND status = 'queued'", arguments: [id])
        }
    }

    func enqueueRun(_ run: ChatRunRecord, budget: Int = 12) throws -> ChatRunRecord {
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
            return run
        }
    }

    /// Claim only a still-queued run after all asynchronous process preparation has finished.
    func claimQueuedRun(_ id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE chat_runs SET status = 'running' WHERE id = ? AND status = 'queued'", arguments: [id])
            return db.changesCount == 1
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
                UPDATE chat_runs SET input = CASE WHEN ? = 'running' THEN '' ELSE input END, status = ?,
                    resultDeliveredAt = CASE WHEN ? IN ('completed', 'failed', 'interrupted') THEN NULL ELSE resultDeliveredAt END
                WHERE id = ?
                """,
                arguments: [status, status, status, id]
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
                AND (? IS NULL OR threadID = ?) AND (?=0 OR origin<>'schedule')
            """, arguments: [accountID, threadID, threadID, preservingSchedules])
        }
    }

    func queuedRuns(accountID: String) throws -> [ChatRunRecord] {
        try dbQueue.read { db in
            try ChatRunRecord.fetchAll(db, sql: """
            SELECT r.* FROM chat_runs r JOIN chat_threads t ON t.id = r.threadID
            WHERE t.accountID = ? AND r.status = 'queued' ORDER BY r.createdAt, r.id LIMIT 100
            """, arguments: [accountID])
        }
    }

    func undeliveredRuns(requesterID: String) throws -> [ChatRunRecord] {
        try dbQueue.read { db in
            try ChatRunRecord.fetchAll(db, sql: """
            SELECT * FROM chat_runs WHERE requestedByThreadID = ? AND resultDeliveredAt IS NULL
                AND status IN ('completed', 'interrupted', 'failed', 'waitingForUser')
            ORDER BY createdAt, id LIMIT 100
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
