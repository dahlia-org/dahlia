import DahliaRuntimeSupport
import Foundation
import GRDB

/// Database transactions serialize every writer, including Settings and review approvals.
struct AgentMemoryService: Sendable {
    let dbQueue: any DatabaseWriter
    static let delimiter = "\n§\n"
    static func limit(_ target: String) -> Int { target == "user" ? 1375 : 2200 }

    struct Operation: Decodable, Sendable {
        var action: String
        var content: String?
        var oldText: String?
        enum CodingKeys: String, CodingKey { case action, content
            case oldText = "old_text"
        }
    }

    struct Request: Decodable, Sendable {
        var target: String
        var operations: [Operation]
    }

    func entries(account: String, target: String? = nil) throws -> [AgentMemoryRecord] {
        try dbQueue.read {
            try Self.entries($0, account: account, target: target)
        }
    }

    private static func entries(_ db: Database, account: String, target: String?) throws -> [AgentMemoryRecord] {
        try AgentMemoryRecord.fetchAll(
            db,
            sql: "SELECT * FROM agent_memories WHERE accountID=? AND (? IS NULL OR target=?) ORDER BY position,createdAt,id",
            arguments: [account, target, target]
        )
    }

    static func usage(_ rows: [AgentMemoryRecord], target: String) -> String {
        let count = HermesLearning.count(rows.map(\.content).joined(separator: delimiter))
        let format = IntegerFormatStyle<Int>.number.locale(Locale(identifier: "en_US"))
        return "\(min(100, Int(Double(count) / Double(limit(target)) * 100)))% — \(count.formatted(format))/\(limit(target).formatted(format)) chars"
    }

    func snapshot(account: String) throws -> String {
        try ["memory", "user"].compactMap { target -> String? in
            let rows = try entries(account: account, target: target)
            guard !rows.isEmpty else { return nil }
            let title = target == "user" ? "USER PROFILE (who the user is)" : "MEMORY (your personal notes)"
            let separator = String(repeating: "═", count: 46)
            return "\(separator)\n\(title) [\(Self.usage(rows, target: target))]\n\(separator)\n\(rows.map(\.content).joined(separator: Self.delimiter))"
        }.joined(separator: "\n\n")
    }

    func execute(
        _ payload: JSONValue,
        account: String,
        thread: String?,
        review: String? = nil,
        createdBy: String = "agent",
        authorize: @Sendable (Database) throws -> Void = { _ in }
    ) throws -> JSONValue {
        let request = try JSONDecoder().decode(Request.self, from: JSONEncoder().encode(payload))
        guard ["user", "memory"].contains(request.target),
              !request.operations.isEmpty else { throw HermesLearning.failure("Expected target=user|memory and a nonempty operations array.") }
        do {
            return try dbQueue.write { db in
                try authorize(db)
                let original = try Self.entries(db, account: account, target: request.target)
                var rows = original
                var changes: [AgentLearningChangeRecord] = []
                for op in request.operations {
                    var before: AgentMemoryRecord?
                    var after: AgentMemoryRecord?
                    switch op.action {
                    case "add":
                        let content = try Self.content(op.content)
                        if rows.contains(where: { $0.content == content }) { continue }
                        let row = AgentMemoryRecord(
                            id: .v7(),
                            accountID: account,
                            target: request.target,
                            content: content,
                            createdBy: createdBy,
                            createdAt: .now,
                            updatedAt: .now,
                            position: (rows.map(\.position).max() ?? -1) + 1
                        )
                        rows.append(row)
                        after = row
                    case "patch", "remove":
                        guard let old = op.oldText,
                              !old.isEmpty else { throw HermesLearning.failure("old_text must be a nonempty exact substring.") }
                        let matches = Self.matches(old, rows: rows)
                        guard matches.count == 1,
                              let index = matches.first else { throw HermesLearning.failure("old_text must match exactly one entry.") }
                        before = rows[index]
                        if op.action == "remove" {
                            rows.remove(at: index)
                        } else {
                            guard let span = rows[index].content.range(of: old),
                                  rows[index].content.range(
                                      of: old,
                                      range: rows[index].content.index(after: span.lowerBound) ..< rows[index].content.endIndex
                                  ) == nil
                            else { throw HermesLearning.failure("old_text occurs more than once; use a longer span.") }
                            guard let replacement = op.content, !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                throw HermesLearning.failure("patch requires nonempty content. Use a longer span to remove part of an entry.")
                            }
                            let patched = try Self.content(rows[index].content.replacingOccurrences(of: old, with: replacement))
                            guard patched != rows[index].content else { throw HermesLearning.failure("Patch is a no-op.") }
                            rows[index].content = patched
                            rows[index].createdBy = createdBy
                            rows[index].updatedAt = .now
                            after = rows[index]
                        }
                    default: throw HermesLearning.failure("Unknown action. Use add, patch, or remove.")
                    }
                    let id = (before ?? after)!.id
                    try changes.append(AgentLearningChangeRecord(
                        id: .v7(), accountID: account, kind: "memory", target: id.uuidString,
                        before: before.map(HermesLearning.json), after: after.map(HermesLearning.json),
                        status: review != nil && before != nil ? "pending" : "applied",
                        source: review == nil ? "interactive" : "review", threadID: thread, reviewID: review, createdAt: .now
                    ))
                }
                guard HermesLearning.count(rows.map(\.content).joined(separator: Self.delimiter)) <= Self.limit(request.target)
                else { throw HermesLearning.failure("Memory character budget exceeded. Consolidate entries in one atomic batch.") }
                // Save the ledger first. Any failure rolls back both proposals and live entries.
                for change in changes {
                    try change.insert(db)
                    if change.status == "applied" {
                        try Self.apply(change.after, target: change.target, in: db)
                    }
                }
                let live = try Self.entries(db, account: account, target: request.target)
                guard HermesLearning.count(live.map(\.content).joined(separator: Self.delimiter)) <= Self.limit(request.target)
                else { throw HermesLearning.failure("Pending removals do not free space until approved.") }
                return .object([
                    "success": .bool(true), "done": .bool(true), "target": .string(request.target),
                    "usage": .string(Self.usage(live, target: request.target)), "entry_count": .number(Double(live.count)),
                    "note": .string(changes
                        .contains(where: { $0.status == "pending" }) ? "Changes staged for user approval; existing entries retained." :
                        "Write saved. This update is complete — do not repeat it."),
                ])
            }
        } catch {
            let rows = try entries(account: account, target: request.target)
            return .object([
                "success": .bool(false),
                "error": .string(error.localizedDescription),
                "entries": .array(rows.map { .string($0.content) }),
                "usage": .string(Self.usage(rows, target: request.target)),
            ])
        }
    }

    private static func matches(_ old: String, rows: [AgentMemoryRecord]) -> [Int] {
        let exact = rows.indices.filter { rows[$0].content == old }
        if !exact.isEmpty { return exact }
        let substring = rows.indices.filter { rows[$0].content.contains(old) }
        if !substring.isEmpty { return substring }
        let needle = normalizedMatch(old)
        guard needle.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return [] }
        return rows.indices.filter { normalizedMatch(rows[$0].content).contains(needle) }
    }

    private static func normalizedMatch(_ text: String) -> String {
        let folded = text.replacingOccurrences(of: "\\n", with: " ").map { character -> Character in
            if "\"`‘’‚‛“”„‟".contains(character) { return "'" }
            if "‐‑‒–—―−".contains(character) { return "-" }
            return character
        }
        return String(folded).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func content(_ value: String?) throws -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              !value.contains("§") else { throw HermesLearning.failure("Content must be nonempty and cannot contain the § entry delimiter.") }
        try HermesLearning.validate(value)
        return value
    }

    private static func apply(_ json: String?, target: String, in db: Database) throws {
        if let json {
            try JSONDecoder().decode(AgentMemoryRecord.self, from: Data(json.utf8)).save(db)
        } else {
            try db.execute(sql: "DELETE FROM agent_memories WHERE id=?", arguments: [UUID(uuidString: target)])
        }
    }

    func changes(account: String) throws -> [AgentLearningChangeRecord] {
        try dbQueue.read {
            try AgentLearningChangeRecord.fetchAll(
                $0,
                sql: """
                SELECT * FROM agent_learning_changes WHERE accountID=? AND (status='pending' OR id IN
                    (SELECT id FROM agent_learning_changes WHERE accountID=? AND status<>'pending' ORDER BY createdAt DESC,id DESC LIMIT 100))
                ORDER BY createdAt DESC,id DESC
                """,
                arguments: [account, account]
            )
        }
    }

    func resolve(id: UUID, account: String, action: String) throws {
        try dbQueue.write { db in
            guard var change = try AgentLearningChangeRecord.fetchOne(db, key: id), change.accountID == account,
                  change.kind == "memory" else { throw HermesLearning.failure("Change not found.") }
            if action == "discard", change.status == "pending" {
                change.status = "discarded"
            } else {
                let approving = action == "approve" && change.status == "pending"
                let reverting = action == "undo" && change.status == "applied"
                guard approving || reverting else { throw HermesLearning.failure("This change cannot be applied.") }
                let current = try AgentMemoryRecord.fetchOne(db, key: UUID(uuidString: change.target))
                let expected = approving ? change.before : change.after
                let expectedRow = try expected.map {
                    try JSONDecoder().decode(AgentMemoryRecord.self, from: Data($0.utf8))
                }
                let sameEntry = current?.id == expectedRow?.id && current?.content == expectedRow?.content && current?.createdBy == expectedRow?
                    .createdBy && current?.accountID == expectedRow?.accountID && current?.target == expectedRow?.target
                guard sameEntry
                else { throw HermesLearning.failure("The entry changed since this proposal. Review the current entry before editing it.") }
                let replacement = approving ? change.after : change.before
                try Self.apply(replacement, target: change.target, in: db)
                for target in ["user", "memory"] {
                    let rows = try Self.entries(db, account: account, target: target)
                    guard HermesLearning.count(rows.map(\.content).joined(separator: Self.delimiter)) <= Self.limit(target)
                    else { throw HermesLearning.failure("Memory character budget exceeded.") }
                }
                change.status = approving ? "applied" : "reverted"
            }
            try change.update(db)
        }
    }
}
