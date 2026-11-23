import DahliaRuntimeSupport
import Foundation
import GRDB

struct ChatThreadStore: ChatItemStore, Sendable {
    let dbQueue: any DatabaseWriter

    func createThread(_ thread: ChatThreadRecord, items: [JSONValue] = [], initialContext: CodexChatContext? = nil) throws {
        try dbQueue.write { db in
            if let parentID = thread.parentThreadID {
                guard let parent = try ChatThreadRecord.fetchOne(db, key: parentID),
                      parent.accountID == thread.accountID else {
                    throw PiRuntimeError.invalidProtocolResponse
                }
            }
            try thread.insert(db)
            try Self.append(items, threadID: thread.id, in: db)
            if let initialContext {
                try Self.attachInitialProject(context: initialContext, threadID: thread.id, in: db)
            }
            if let message = items.first {
                try Self.attachInitialProject(message: message, threadID: thread.id, in: db)
            }
        }
    }

    func thread(id: String, accountID: String) throws -> ChatThreadRecord {
        try dbQueue.read { db in
            guard let thread = try ChatThreadRecord.fetchOne(db, key: id), thread.accountID == accountID else {
                throw PiRuntimeError.rpcError(code: nil, message: "thread not found")
            }
            return thread
        }
    }

    func listThreads(accountID: String, cursor: String?, limit: Int = 25) throws -> CodexChatThreadPage {
        try dbQueue.read { db in
            var condition = ""
            var arguments: StatementArguments = [accountID]
            if let cursor, let data = Data(base64Encoded: cursor),
               let values = try? JSONDecoder().decode([String].self, from: data), values.count == 2,
               let time = Double(values[0]) {
                condition = "AND (updatedAt, id) < (?, ?)"
                let date = Date(timeIntervalSince1970: time)
                arguments += [date, values[1]]
            }
            arguments += [limit + 1]
            let rows = try ChatThreadRecord.fetchAll(db, sql: """
            SELECT * FROM chat_threads WHERE accountID = ? \(condition)
            ORDER BY updatedAt DESC, id DESC LIMIT ?
            """, arguments: arguments)
            let visible = Array(rows.prefix(limit))
            let next = try rows.count > limit ? visible.last.map {
                try JSONEncoder().encode([String($0.updatedAt.timeIntervalSince1970), $0.id]).base64EncodedString()
            } : nil
            return try CodexChatThreadPage(threads: visible.map { thread in
                let response = try Row.fetchOne(db, sql: """
                SELECT seq, createdAt FROM chat_items WHERE threadID = ? AND \(ChatItemRecord.messagePredicate())
                    AND json_extract(data, '$.role') = 'assistant' ORDER BY seq DESC LIMIT 1
                """, arguments: [thread.id])
                let responseSeq: Int64 = response?["seq"] ?? -1
                let scheduledUnread = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM chat_schedule_fires WHERE scheduleID=? AND status='delivered' AND resultSeq>?)",
                    arguments: [thread.scheduleID, thread.lastSeenSeq]
                ) ?? false
                return try CodexChatThreadSummary(
                    id: thread.id,
                    title: thread.title,
                    updatedAt: thread.updatedAt,
                    parentThreadID: thread.parentThreadID,
                    status: thread.status,
                    isUnread: thread.scheduleID == nil ? responseSeq > thread.lastSeenSeq : scheduledUnread,
                    lastResponseAt: response?["createdAt"],
                    lastItemSeq: Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM chat_items WHERE threadID = ?", arguments: [thread.id])
                )
            }, nextCursor: next)
        }
    }

    func markThreadSeen(id: String, accountID: String, through seq: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE chat_threads SET lastSeenSeq = MAX(lastSeenSeq, ?) WHERE id = ? AND accountID = ?",
                arguments: [seq, id, accountID]
            )
        }
    }

    func parentSummary(for record: ChatThreadRecord) throws -> CodexChatThreadSummary? {
        try record.parentThreadID.map { parentID in
            let parent = try thread(id: parentID, accountID: record.accountID)
            return CodexChatThreadSummary(id: parent.id, title: parent.title, updatedAt: parent.updatedAt)
        }
    }

    func updateThread(id: String, title: String? = nil, status: String? = nil, model: String? = nil, effort: String? = nil) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
            UPDATE chat_threads SET title = COALESCE(?, title), status = COALESCE(?, status),
                model = COALESCE(?, model), reasoningEffort = COALESCE(?, reasoningEffort), updatedAt = ? WHERE id = ?
            """, arguments: [title, status, model, effort, Date(), id])
        }
    }

    func beginTurn(threadID: String, message: JSONValue, model: String?, effort: String, runID: UUID? = nil) throws {
        try dbQueue.write { db in
            try Self.append([message], threadID: threadID, runID: runID, in: db)
            try db.execute(sql: """
            UPDATE chat_threads SET status = 'running', model = COALESCE(?, model), reasoningEffort = ?, updatedAt = ? WHERE id = ?
            """, arguments: [model, effort, Date(), threadID])
        }
    }

    func appendItems(threadID: String, items: [JSONValue]) throws {
        try appendItems(threadID: threadID, items: items, runID: nil)
    }

    func appendItems(threadID: String, items: [JSONValue], runID: UUID?) throws {
        guard !items.isEmpty else { return }
        try dbQueue.write { db in
            try Self.append(items, threadID: threadID, runID: runID, in: db)
            try db.execute(sql: "UPDATE chat_threads SET updatedAt = ? WHERE id = ?", arguments: [Date(), threadID])
        }
    }

    func listItems(threadID: String, after: Int64? = nil, limit: Int = 100) throws -> [ChatItemRecord] {
        try dbQueue.read { db in
            try ChatItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM chat_items WHERE threadID = ? AND seq > ? ORDER BY seq LIMIT ?",
                arguments: [threadID, after ?? -1, min(max(limit, 1), 100)]
            )
        }
    }

    func listItems(threadID: String, cursor: String?, limit: Int) throws -> ChatItemPage {
        let rows = try listItems(threadID: threadID, after: cursor.flatMap(Int64.init), limit: limit)
        return try ChatItemPage(
            items: rows.map(ChatItem.init),
            nextCursor: rows.count == min(max(limit, 1), 100) ? rows.last.map { String($0.seq) } : nil
        )
    }

    func messagePage(threadID: String, before: Int64? = nil, limit: Int = 40) throws -> CodexChatMessagePage {
        let pageSize = min(max(limit, 1), 100)
        let rows = try dbQueue.read { db in
            try ChatItemRecord.fetchAll(db, sql: """
            SELECT * FROM chat_items WHERE threadID = ? AND seq < ?
                AND \(ChatItemRecord.conversationPredicate())
            ORDER BY seq DESC LIMIT ?
            """, arguments: [threadID, before ?? Int64.max, pageSize + 1])
        }
        let visible = Array(rows.prefix(pageSize).reversed())
        return try CodexChatMessagePage(
            messages: ChatHistoryCodec.messages(visible),
            earlierCursor: rows.count > pageSize ? visible.first.map { String($0.seq) } : nil,
            lastItemSeq: visible.last?.seq
        )
    }

    func hasAssistantReply(threadID: String) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM chat_items WHERE threadID = ? AND json_extract(data, '$.role') = 'assistant')
            """, arguments: [threadID]) ?? false
        }
    }

    static func firstMessagePreview(threadID: String, in db: Database) throws -> String? {
        guard let content = try String.fetchOne(db, sql: """
        SELECT COALESCE(
            (SELECT json_extract(data, '$.content') FROM chat_items
             WHERE threadID = ? AND json_extract(data, '$.role') = 'user' ORDER BY seq LIMIT 1),
            (SELECT input FROM chat_runs WHERE threadID = ? ORDER BY createdAt, id LIMIT 1)
        )
        """, arguments: [threadID, threadID]) else { return nil }
        var text = CodexChatPromptCodec.visibleUserText(from: content)
        let start = "<thread_request source=\"dahlia\" untrusted=\"true\">\n"
        let end = "\n</thread_request>"
        if text.hasPrefix(start), text.hasSuffix(end),
           let payload = try? JSONDecoder().decode(JSONValue.self, from: Data(text.dropFirst(start.count).dropLast(end.count).utf8)),
           let input = payload.objectValue?["input"]?.stringValue {
            text = CodexChatPromptCodec.visibleUserText(from: input)
        }
        return String(text.prefix(1000))
    }

    func deleteThread(id: String) throws {
        _ = try dbQueue.write {
            try ChatThreadRecord.deleteOne($0, key: id)
        }
    }

    func recoverInterruptedThreads() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE chat_threads SET status = 'interrupted' WHERE status IN ('running', 'waitingForUser')")
            try db.execute(
                sql: "UPDATE chat_runs SET status = 'interrupted', resultDeliveredAt = ? WHERE status IN ('queued', 'running', 'waitingForUser') AND NOT (origin='schedule' AND status='queued')",
                arguments: [Date()]
            )
        }
    }

    private static func attachInitialProject(message: JSONValue, threadID: String, in db: Database) throws {
        let content = message.objectValue?["content"]?.stringValue ?? ""
        let context = CodexChatPromptCodec.decodeTextBlocks([content]).context
        try attachInitialProject(context: context, threadID: threadID, in: db)
    }

    private static func attachInitialProject(context: CodexChatContext?, threadID: String, in db: Database) throws {
        let accountID = try String.fetchOne(db, sql: "SELECT accountID FROM chat_threads WHERE id = ?", arguments: [threadID])
        let projectID: UUID? = switch context {
        case let .project(id, _, _): id
        case let .meeting(id, _, _): try MeetingRecord.fetchOne(db, key: id)?.projectId
        default: nil
        }
        if let projectID, let project = try ProjectRecord.fetchOne(db, key: projectID),
           try WorkspaceRecord.exists(db, key: project.workspaceId),
           AppAccount.key == accountID {
            try db.execute(sql: "UPDATE chat_threads SET projectID = ? WHERE id = ? AND projectID IS NULL", arguments: [projectID, threadID])
        }
    }

    static func append(_ items: [JSONValue], threadID: String, runID: UUID? = nil, inferRunID: Bool = true, in db: Database) throws {
        let owner = try runID ?? (inferRunID ? ChatRunRecord.fetchOne(
            db,
            sql: "SELECT * FROM chat_runs WHERE threadID=? AND status IN ('running','waitingForUser') ORDER BY createdAt DESC LIMIT 1",
            arguments: [threadID]
        )?.id : nil)
        var seq = try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM chat_items WHERE threadID = ?", arguments: [threadID]) ?? -1
        for item in items {
            seq += 1
            try ChatItemRecord(
                id: .v7(),
                threadID: threadID,
                seq: seq,
                data: String(decoding: JSONEncoder().encode(item), as: UTF8.self),
                createdAt: .now, runID: owner
            ).insert(db)
        }
    }
}
