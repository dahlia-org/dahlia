import DahliaRuntimeSupport
import Foundation
import GRDB

struct ChatThreadStore: ChatItemStore, Sendable {
    let dbQueue: DatabaseQueue

    func createThread(_ thread: ChatThreadRecord, items: [JSONValue] = [], importIfMissing: Bool = false) throws {
        try dbQueue.write { db in
            if importIfMissing, try ChatThreadRecord.exists(db, key: thread.id) { return }
            if let parentID = thread.parentThreadID {
                guard let parent = try ChatThreadRecord.fetchOne(db, key: parentID),
                      parent.accountID == thread.accountID, parent.workspaceID == thread.workspaceID else {
                    throw PiRuntimeError.invalidProtocolResponse
                }
            }
            try thread.insert(db)
            try Self.append(items, threadID: thread.id, in: db)
            if let message = items.first { try Self.attachInitialProject(message: message, threadID: thread.id, in: db) }
        }
    }

    func thread(id: String, accountID: String, workspaceID: UUID? = nil) throws -> ChatThreadRecord {
        try dbQueue.read { db in
            guard let thread = try ChatThreadRecord.fetchOne(db, key: id), thread.accountID == accountID,
                  workspaceID == nil || workspaceID == thread.workspaceID else {
                throw PiRuntimeError.rpcError(code: nil, message: "thread not found")
            }
            return thread
        }
    }

    func listThreads(accountID: String, workspaceID: UUID, cursor: String?, limit: Int = 25) throws -> CodexChatThreadPage {
        try dbQueue.read { db in
            var condition = ""
            var arguments: StatementArguments = [accountID, workspaceID]
            if let cursor, let data = Data(base64Encoded: cursor),
               let values = try? JSONDecoder().decode([String].self, from: data), values.count == 2,
               let time = Double(values[0]) {
                condition = "AND (updatedAt, id) < (?, ?)"
                let date = Date(timeIntervalSince1970: time)
                arguments += [date, values[1]]
            }
            arguments += [limit + 1]
            let rows = try ChatThreadRecord.fetchAll(db, sql: """
            SELECT * FROM chat_threads WHERE accountID = ? AND workspaceID = ? \(condition)
            ORDER BY updatedAt DESC, id DESC LIMIT ?
            """, arguments: arguments)
            let visible = Array(rows.prefix(limit))
            let next = try rows.count > limit ? visible.last.map {
                try JSONEncoder().encode([String($0.updatedAt.timeIntervalSince1970), $0.id]).base64EncodedString()
            } : nil
            return CodexChatThreadPage(threads: visible.map {
                CodexChatThreadSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt)
            }, nextCursor: next)
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

    func beginTurn(threadID: String, message: JSONValue, model: String?, effort: String) throws {
        try dbQueue.write { db in
            let firstSequence = try Self.append([message], threadID: threadID, in: db)
            try db.execute(sql: """
            UPDATE chat_threads SET status = 'running', model = COALESCE(?, model), reasoningEffort = ?, updatedAt = ? WHERE id = ?
            """, arguments: [model, effort, Date(), threadID])
            // The initial context decides the Project; later turns may discuss other Projects.
            if firstSequence == 0 {
                try Self.attachInitialProject(message: message, threadID: threadID, in: db)
            }
        }
    }

    func appendItems(threadID: String, items: [JSONValue]) throws {
        try dbQueue.write { db in
            try Self.append(items, threadID: threadID, in: db)
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
                AND \(ChatItemRecord.messagePredicate())
            ORDER BY seq DESC LIMIT ?
            """, arguments: [threadID, before ?? Int64.max, pageSize + 1])
        }
        let visible = Array(rows.prefix(pageSize).reversed())
        return try CodexChatMessagePage(
            messages: ChatHistoryCodec.messages(visible),
            earlierCursor: rows.count > pageSize ? visible.first.map { String($0.seq) } : nil
        )
    }

    func hasAssistantReply(threadID: String) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM chat_items WHERE threadID = ? AND json_extract(data, '$.role') = 'assistant')
            """, arguments: [threadID]) ?? false
        }
    }

    func deleteThread(id: String) throws {
        _ = try dbQueue.write { try ChatThreadRecord.deleteOne($0, key: id) }
    }

    func recoverInterruptedThreads() throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE chat_threads SET status = 'interrupted' WHERE status IN ('running', 'waitingForUser')")
        }
    }

    private static func attachInitialProject(message: JSONValue, threadID: String, in db: Database) throws {
        let content = message.objectValue?["content"]?.stringValue ?? ""
        let context = CodexChatPromptCodec.decodeTextBlocks([content]).context
        let workspaceID = try UUID.fetchOne(db, sql: "SELECT workspaceID FROM chat_threads WHERE id = ?", arguments: [threadID])
        let projectID: UUID? = switch context {
        case let .project(id, _, _): id
        case let .meeting(id, _, _): try MeetingRecord.fetchOne(db, key: id)?.projectId
        default: nil
        }
        if let projectID, let project = try ProjectRecord.fetchOne(db, key: projectID), project.workspaceId == workspaceID {
            try db.execute(sql: "UPDATE chat_threads SET projectID = ? WHERE id = ?", arguments: [projectID, threadID])
        }
    }

    @discardableResult
    private static func append(_ items: [JSONValue], threadID: String, in db: Database) throws -> Int64 {
        var seq = try Int64.fetchOne(db, sql: "SELECT MAX(seq) FROM chat_items WHERE threadID = ?", arguments: [threadID]) ?? -1
        let firstSequence = seq + 1
        for item in items {
            seq += 1
            try ChatItemRecord(
                id: .v7(),
                threadID: threadID,
                seq: seq,
                data: String(decoding: JSONEncoder().encode(item), as: UTF8.self),
                createdAt: .now
            ).insert(db)
        }
        return firstSequence
    }
}
