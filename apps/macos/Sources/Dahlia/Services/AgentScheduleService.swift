import DahliaRuntimeSupport
import Foundation
import GRDB

struct AgentScheduleService: Sendable {
    let dbQueue: DatabaseQueue
    func list(account: String) throws -> [ChatScheduleRecord] {
        try dbQueue.read {
            try ChatScheduleRecord.fetchAll(
                $0,
                sql: "SELECT * FROM chat_schedules WHERE accountID=? ORDER BY createdAt,id",
                arguments: [account]
            )
        }
    }

    func record(id: String, account: String) throws -> ChatScheduleRecord {
        guard let row = try list(account: account).first(where: { $0.id == id })
        else { throw HermesLearning.failure("Schedule not found. List schedules first.") }
        return row
    }

    func execute(
        _ payload: JSONValue,
        account: String,
        approved: Bool,
        tools: [String],
        now: Date = .now,
        expectedRevision: Int? = nil
    ) throws -> JSONValue {
        let args = payload.objectValue ?? [:]
        let action = args["action"]?.stringValue ?? ""
        if action == "list" { return try Self.value(list(account: account)) }
        let id = args["job_id"]?.stringValue ?? UUID.v7().uuidString
        if action == "create" {
            guard approved, let schedule = args["schedule"]?.stringValue, let prompt = args["prompt"]?.stringValue,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw HermesLearning.failure("Creation requires user confirmation, schedule and prompt.") }
            let parsed = try AgentSchedule.parse(schedule, now: now)
            let threadID = UUID.v7().uuidString
            let name = args["name"]?.stringValue ?? String(prompt.prefix(80))
            let skills = args["skills"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let row = try ChatScheduleRecord(
                id: id,
                accountID: account,
                threadID: threadID,
                name: name,
                schedule: schedule,
                prompt: prompt,
                skills: HermesLearning.json(skills),
                allowedTools: HermesLearning.json(tools.sorted()),
                revision: 1,
                enabled: true,
                nextFireAt: parsed.next(after: now),
                createdAt: now,
                updatedAt: now
            )
            try dbQueue.write { db in
                var thread = ChatThreadRecord(id: threadID, accountID: account, title: name, createdAt: now, updatedAt: now)
                thread.scheduleID = id
                try thread.insert(db)
                try row.insert(db)
            }
            return try Self.value(row)
        }
        var row = try record(id: id, account: account)
        switch action {
        case "run":
            guard row.enabled else { throw HermesLearning.failure("Resume and approve this schedule before running it.") }
            try enqueue(row, now: now, key: UUID.v7().uuidString)
        case "pause", "resume", "update", "remove":
            if action == "resume" || (action == "update" && row.enabled) {
                guard approved,
                      expectedRevision == row.revision
                else { throw HermesLearning.failure("Activation requires confirmation of the current revision.") }
                row.allowedTools = try HermesLearning.json(tools.sorted())
            }
            if action == "update" {
                row.name = args["name"]?.stringValue ?? row.name
                row.prompt = args["prompt"]?.stringValue ?? row.prompt
                row.schedule = args["schedule"]?.stringValue ?? row.schedule
                guard !row.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw HermesLearning.failure("The schedule prompt must not be empty.")
                }
                _ = try AgentSchedule.parse(row.schedule, now: now)
                if let skills = args["skills"]?.arrayValue { row.skills = try HermesLearning.json(skills.compactMap(\.stringValue)) }
            }
            if action == "pause" || action == "resume" { row.enabled = action == "resume" }
            row.revision += 1
            row.updatedAt = now
            if row.enabled { row.nextFireAt = try AgentSchedule.parse(row.schedule, now: now).next(after: now) }
            try dbQueue.write { db in
                guard let current = try ChatScheduleRecord.fetchOne(db, key: row.id), current.revision == row.revision - 1 else {
                    throw HermesLearning.failure("Schedule changed while editing. Reload and retry.")
                }
                try Self.skipQueued(row.id, in: db)
                if action == "remove" { try row.delete(db) } else {
                    try row.update(db)
                }
                try db.execute(sql: "UPDATE chat_threads SET title=? WHERE id=?", arguments: [row.name, row.threadID])
            }
        default: throw HermesLearning.failure("Unknown action. Use create, list, update, pause, resume, remove, run.")
        }
        return try Self.value(row)
    }

    func tick(account: String, now: Date = .now) throws {
        for row in try list(account: account) where row.enabled && row.nextFireAt.map({ $0 <= now }) == true {
            try enqueue(row, now: now, key: String(row.nextFireAt!.timeIntervalSince1970))
        }
    }

    private func enqueue(_ row: ChatScheduleRecord, now: Date, key: String) throws {
        try dbQueue.write { db in
            guard let current = try ChatScheduleRecord.fetchOne(db, key: row.id), current.enabled, current.revision == row.revision else { return }
            let queued = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM chat_schedule_fires WHERE scheduleID=? AND status='queued')",
                arguments: [row.id]
            ) ?? false
            if !queued {
                let id = UUID.v7()
                try db.execute(
                    sql: "INSERT OR IGNORE INTO chat_schedule_fires(scheduleID,fireKey,revision,runID,status,createdAt) VALUES(?,?,?,?,'queued',?)",
                    arguments: [row.id, key, row.revision, id, now]
                )
                if db.changesCount == 1 {
                    let previous = try String.fetchOne(
                        db,
                        sql: "SELECT r.resultExcerpt FROM chat_schedule_fires f JOIN chat_runs r ON r.id=f.runID WHERE f.scheduleID=? AND f.status='delivered' ORDER BY f.createdAt DESC LIMIT 1",
                        arguments: [row.id]
                    ) ?? ""
                    var prompt = HermesLearning.prompts["cron_hint"] ?? ""
                    if !previous
                        .isEmpty { prompt += "\n" + (HermesLearning.prompts["self_context_intro"] ?? "") + "\n" + String(previous.prefix(8000)) }
                    let skills = (try? JSONDecoder().decode([String].self, from: Data(row.skills.utf8))) ?? []
                    prompt += "\n\nLoad these skills with skill_view before working: \(skills.joined(separator: ", ")).\n\n" + row.prompt
                    var run = ChatRunRecord(
                        id: id,
                        threadID: row.threadID,
                        rootRunID: id,
                        status: "queued",
                        input: prompt,
                        effort: "medium",
                        approvalMethod: "ask",
                        createdAt: now
                    )
                    run.origin = "schedule"
                    run.profile = "scheduled"
                    try run.insert(db)
                }
            }
            // Coalesce missed intervals and suspend a completed one-shot.
            let parsed = try? AgentSchedule.parse(row.schedule, now: row.createdAt.addingTimeInterval(-1))
            let next = parsed?.next(after: now)
            try db.execute(sql: "UPDATE chat_schedules SET nextFireAt=? WHERE id=?", arguments: [next, row.id])
        }
    }

    func validateStart(_ run: ChatRunRecord, account: String) throws -> Bool {
        guard run.origin == "schedule" else { return true }
        return try dbQueue.write { db in
            let valid = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM chat_schedule_fires f JOIN chat_schedules s ON s.id=f.scheduleID
            WHERE f.runID=? AND f.status='queued' AND s.enabled=1 AND s.revision=f.revision AND s.accountID=?)
            """, arguments: [run.id, account]) ?? false
            if !valid {
                try db.execute(sql: "UPDATE chat_schedule_fires SET status='skipped' WHERE runID=? AND status='queued'", arguments: [run.id])
                try db.execute(sql: "UPDATE chat_runs SET status='interrupted' WHERE id=? AND status='queued'", arguments: [run.id])
            }
            return valid
        }
    }

    func allowedTools(runID: UUID, account: String) throws -> [String] {
        try dbQueue.read { db in
            let text = try String.fetchOne(
                db,
                sql: "SELECT s.allowedTools FROM chat_schedules s JOIN chat_schedule_fires f ON f.scheduleID=s.id WHERE f.runID=? AND s.accountID=?",
                arguments: [runID, account]
            ) ?? "[]"
            return try JSONDecoder().decode([String].self, from: Data(text.utf8))
        }
    }

    func started(_ run: ChatRunRecord) throws {
        try dbQueue.write {
            try $0.execute(
                sql: "UPDATE chat_schedule_fires SET status='running' WHERE runID=? AND status='queued'",
                arguments: [run.id]
            )
        }
    }

    @discardableResult
    func settled(_ run: ChatRunRecord, status: String) throws -> String {
        try dbQueue.write { db in
            let kind = try String.fetchOne(db, sql: "SELECT resultKind FROM chat_schedule_fires WHERE runID=?", arguments: [run.id])
            let result = status == "completed" ? (kind ?? AgentSchedule.result(
                run.resultExcerpt
            )) : status == "interrupted" ? "interrupted" : "failed"
            let seq = try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM chat_items WHERE threadID=? AND runID=?", arguments: [run.threadID, run.id])
            try db.execute(sql: "UPDATE chat_schedule_fires SET status=?,resultSeq=? WHERE runID=?", arguments: [result, seq, run.id])
            return result
        }
    }

    func markSeen(thread: String, account: String) throws {
        try dbQueue.write {
            try $0.execute(
                sql: "UPDATE chat_threads SET lastSeenSeq=COALESCE((SELECT MAX(seq) FROM chat_items WHERE threadID=?),-1) WHERE id=? AND accountID=?",
                arguments: [thread, thread, account]
            )
        }
    }

    func unread(thread: String, account: String) throws -> Bool {
        try dbQueue.read {
            try Bool.fetchOne(
                $0,
                sql: """
                SELECT EXISTS(SELECT 1 FROM chat_threads t JOIN chat_schedule_fires f ON f.scheduleID=t.scheduleID
                WHERE t.id=? AND t.accountID=? AND f.status='delivered' AND f.resultSeq>t.lastSeenSeq)
                """,
                arguments: [thread, account]
            ) ?? false
        }
    }

    private static func skipQueued(_ schedule: String, in db: Database) throws {
        try db.execute(sql: "UPDATE chat_schedule_fires SET status='skipped' WHERE scheduleID=? AND status='queued'", arguments: [schedule])
        try db.execute(
            sql: "UPDATE chat_runs SET status='interrupted' WHERE status='queued' AND id IN (SELECT runID FROM chat_schedule_fires WHERE scheduleID=?)",
            arguments: [schedule]
        )
    }

    private static func value(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(
            JSONValue.self,
            from: JSONEncoder().encode(value)
        )
    }
}
