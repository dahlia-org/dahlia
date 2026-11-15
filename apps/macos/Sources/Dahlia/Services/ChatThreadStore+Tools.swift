import DahliaRuntimeSupport
import Foundation
import GRDB

extension ChatThreadStore {
    /// A request key is a retry key within one user request (root run), not for the requester's lifetime.
    func requestedRun(requesterID: String, rootRunID: UUID, clientRequestID: String) throws -> ChatRunRecord? {
        try dbQueue.read { db in
            try ChatRunRecord.fetchOne(
                db,
                sql: "SELECT * FROM chat_runs WHERE requestedByThreadID = ? AND rootRunID = ? AND clientRequestID = ?",
                arguments: [requesterID, rootRunID, clientRequestID]
            )
        }
    }

    func latestRun(threadID: String) throws -> ChatRunRecord? {
        try dbQueue.read { db in
            try ChatRunRecord.fetchOne(
                db,
                sql: "SELECT * FROM chat_runs WHERE threadID = ? ORDER BY createdAt DESC, id DESC LIMIT 1",
                arguments: [threadID]
            )
        }
    }

    func setParent(_ threadID: String, parentID: String, accountID: String) throws {
        try dbQueue.write { db in
            guard let parent = try ChatThreadRecord.fetchOne(db, key: parentID), parent.accountID == accountID, parent.parentThreadID == nil,
                  let child = try ChatThreadRecord.fetchOne(db, key: threadID), child.accountID == accountID, child.parentThreadID == nil,
                  threadID != parentID else { throw PiRuntimeError.invalidProtocolResponse }
            try db.execute(sql: "UPDATE chat_threads SET parentThreadID = ? WHERE id = ?", arguments: [parentID, threadID])
        }
    }

    func enqueueNotification(_ run: ChatRunRecord, deliveredRuns: [ChatRunRecord]) throws {
        try dbQueue.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_runs WHERE rootRunID = ?", arguments: [run.rootRunID]) ?? 0
            // Reaching the budget leaves the results available for a later explicit read; no automatic calls follow.
            if count < 12 {
                try run.insert(db)
                try Self.append([.object(["type": .string("thread_notification"), "content": .string(run.input)])], threadID: run.threadID, in: db)
            }
            for delivered in deliveredRuns {
                try db.execute(sql: "UPDATE chat_runs SET resultDeliveredAt = ? WHERE id = ?", arguments: [Date(), delivered.id])
            }
        }
    }

    func toolThreadPage(accountID: String, arguments args: [String: JSONValue]) throws -> JSONValue {
        try dbQueue.read { db in
            var conditions = ["accountID = ?"]
            var values: StatementArguments = [accountID]
            let activeStatus = """
            COALESCE((SELECT status FROM chat_runs WHERE threadID = chat_threads.id
                AND status IN ('running', 'waitingForUser', 'queued')
                ORDER BY CASE status WHEN 'queued' THEN 1 ELSE 0 END, createdAt DESC LIMIT 1), status)
            """
            for (parameter, column) in [("status", activeStatus), ("parent_thread_id", "parentThreadID")] {
                if let value = args[parameter]?.stringValue { conditions.append("\(column) = ?")
                    values += [value]
                }
            }
            if let title = args["title"]?.stringValue { conditions.append("instr(lower(title), lower(?)) > 0")
                values += [String(title.prefix(256))]
            }
            if let raw = args["project_id"]?.stringValue {
                conditions.append("projectID = ?")
                try values += [TypeID.decode(raw, as: .project)]
            }
            if let cursor = args["cursor"]?.stringValue {
                guard let data = Data(base64Encoded: cursor), let parts = try? JSONDecoder().decode([String].self, from: data),
                      parts.count == 2, let timestamp = Double(parts[0]) else { throw PiRuntimeError.invalidProtocolResponse }
                conditions.append("(updatedAt, id) < (?, ?)")
                values += [Date(timeIntervalSince1970: timestamp), parts[1]]
            }
            let limit = min(max(args["limit"]?.intValue ?? 25, 1), 100)
            values += [limit + 1]
            let rows = try ChatThreadRecord.fetchAll(
                db,
                sql: "SELECT * FROM chat_threads WHERE \(conditions.joined(separator: " AND ")) ORDER BY updatedAt DESC, id DESC LIMIT ?",
                arguments: values
            )
            let visible = Array(rows.prefix(limit))
            let cursor = try rows.count > limit ? visible.last
                .map { try JSONEncoder().encode([String($0.updatedAt.timeIntervalSince1970), $0.id]).base64EncodedString() } : nil
            let threads = try visible.map { row -> JSONValue in
                let status = try String.fetchOne(db, sql: "SELECT \(activeStatus) FROM chat_threads WHERE id = ?", arguments: [row.id]) ?? row.status
                return .object([
                    "id": .string(row.id),
                    "title": .string(String(row.title.prefix(256))),
                    "status": .string(status),
                    "parent_thread_id": row.parentThreadID.map(JSONValue.string) ?? .null,
                    "project_id": row.projectID.map { .string(TypeID.encode($0, as: .project)) } ?? .null,
                ])
            }
            return .object(["threads": .array(threads), "next_cursor": cursor.map(JSONValue.string) ?? .null])
        }
    }

    /// Pages by item, and within one long item by `item_cursor` with `text_offset`, so every reply can be read in full.
    func readForTool(threadID: String, arguments: [String: JSONValue]) throws -> JSONValue {
        let limit = min(max(arguments["limit"]?.intValue ?? 30, 1), 100)
        let maximumCharacters = min(max(arguments["max_characters"]?.intValue ?? 4000, 1), 8000)
        let activity = arguments["view"]?.stringValue == "activity"
        let item = arguments["item_cursor"]?.stringValue.flatMap(Int64.init)
        let offset = item == nil ? 0 : max(arguments["text_offset"]?.intValue ?? 0, 0)
        let after = item.map { $0 - 1 } ?? arguments["cursor"]?.stringValue.flatMap(Int64.init) ?? -1
        return try dbQueue.read { db in
            let rows = try ChatItemRecord.fetchAll(db, sql: """
            SELECT * FROM chat_items WHERE threadID = ? AND seq > ? AND (? IS NULL OR seq = ?)
                \(activity ? "" : "AND json_extract(data, '$.type') = 'message' AND json_extract(data, '$.role') IN ('user', 'assistant')")
            ORDER BY seq LIMIT ?
            """, arguments: [threadID, after, item, item, limit + 1])
            var complete = item == nil
            let items = try rows.prefix(limit).map { row -> JSONValue in
                let data = try JSONDecoder().decode(JSONValue.self, from: Data(row.data.utf8)).objectValue ?? [:]
                let type = data["type"]?.stringValue ?? ""
                let content = data["content"]?.stringValue ?? data["result"].map { String(describing: $0) } ?? ""
                let text = (type == "message" ? CodexChatPromptCodec.decodeTextBlocks([content]).text : content).dropFirst(offset)
                let truncated = text.count > maximumCharacters
                if truncated { complete = false }
                return .object([
                    "cursor": .string(String(row.seq)),
                    "type": .string(type),
                    "role": data["role"] ?? .null,
                    "tool": data["name"] ?? .null,
                    "status": data["status"] ?? .null,
                    "text": .string(String(text.prefix(maximumCharacters))),
                    "truncated": .bool(truncated),
                    "next_text_offset": truncated ? .number(Double(offset + maximumCharacters)) : .null,
                ])
            }
            return .object([
                "items": .array(items),
                "next_cursor": rows.count > limit ? .string(String(rows[limit - 1].seq)) : .null,
                // False while a returned item was cut, or when only one item was read.
                "complete": .bool(complete),
                "untrusted": .bool(true),
            ])
        }
    }

    func toolContext(arguments: [String: JSONValue], accountID: String) throws -> CodexChatContext? {
        try dbQueue.read { db in
            if let raw = arguments["meeting_id"]?.stringValue {
                let id = try TypeID.decode(raw, as: .meeting)
                guard let meeting = try MeetingRecord.fetchOne(db, key: id),
                      let workspace = try WorkspaceRecord.fetchOne(db, key: meeting.workspaceId),
                      CodexRuntimeProvider(workspace: workspace).accountKey == accountID else { throw PiRuntimeError.invalidProtocolResponse }
                return .meeting(id: id, name: meeting.name, calendarEvent: nil)
            }
            if let raw = arguments["project_id"]?.stringValue {
                let id = try TypeID.decode(raw, as: .project)
                guard let project = try ProjectRecord.fetchOne(db, key: id),
                      let workspace = try WorkspaceRecord.fetchOne(db, key: project.workspaceId),
                      CodexRuntimeProvider(workspace: workspace).accountKey == accountID else { throw PiRuntimeError.invalidProtocolResponse }
                return .project(id: id, name: project.name, description: project.description)
            }
            return nil
        }
    }
}
