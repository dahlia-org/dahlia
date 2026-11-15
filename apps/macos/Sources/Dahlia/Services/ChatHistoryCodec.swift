import DahliaRuntimeSupport
import Foundation

/// The memory-compatible envelope stays independent of Pi's resume-file format.
enum ChatHistoryCodec {
    static func message(_ message: [String: JSONValue], isSteer: Bool = false) -> JSONValue {
        let blocks = message["content"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let text = message["content"]?.stringValue ?? PiChatSessionFiles.text(blocks, type: "text", key: "text")
        var record: [String: JSONValue] = [
            "type": .string("message"), "role": message["role"] ?? .string("assistant"),
            "content": .string(text),
            "reasoning": .string(PiChatSessionFiles.text(blocks, type: "thinking", key: "thinking")),
            "images": .array(blocks.filter { $0["type"]?.stringValue == "image" }.map(JSONValue.object)),
        ]
        if isSteer { record["deliveryMode"] = .string("steer") }
        return .object(record)
    }

    static func user(_ inputs: [CodexAppServerInput], isSteer: Bool = false) -> JSONValue {
        let prompt = PiRuntimeService.prompt(PiChatService.textJoined(inputs))
        var blocks: [JSONValue] = [.object(["type": .string("text"), "text": prompt["message"] ?? .string("")])]
        blocks += prompt["images"]?.arrayValue ?? []
        return message(["role": .string("user"), "content": .array(blocks)], isSteer: isSteer)
    }

    static func messages(_ items: [ChatItemRecord]) throws -> [CodexChatMessage] {
        try messages(items.map(ChatItem.init))
    }

    static func messages(_ items: [ChatItem]) -> [CodexChatMessage] {
        var messages: [CodexChatMessage] = []
        var records: [[String: JSONValue]] = []
        var steeredIDs: Set<String> = []
        /// A notification starts a run without a user message, so it also ends the reply before it.
        func flush() {
            messages += PiChatSessionFiles.messages(records).map { message in
                var restored = message
                restored.isSteer = message.role == .user && steeredIDs.contains(message.id)
                return restored
            }
            records = []
        }
        for item in items {
            guard let data = item.data.objectValue else { continue }
            switch data["type"]?.stringValue {
            case "thread_notification":
                flush()
                messages.append(CodexChatMessage(
                    id: item.id, role: .notice(.info), text: notificationDisplayText(data["content"]?.stringValue ?? "")
                ))
            case "message":
                if data["deliveryMode"]?.stringValue == "steer" { steeredIDs.insert(item.id) }
                var blocks: [JSONValue] = [.object(["type": .string("text"), "text": data["content"] ?? .string("")])]
                blocks.append(.object(["type": .string("thinking"), "thinking": data["reasoning"] ?? .string("")]))
                blocks += data["images"]?.arrayValue ?? []
                records.append([
                    "type": .string("message"),
                    "id": .string(item.id),
                    "message": .object(["role": data["role"] ?? .null, "content": .array(blocks)]),
                ])
            default:
                continue
            }
        }
        flush()
        return messages
    }

    private static func notificationDisplayText(_ content: String) -> String {
        guard let start = content.firstIndex(of: "\n"), let end = content.range(of: "</thread_results>")?.lowerBound,
              start < end,
              let rows = try? JSONDecoder().decode(JSONValue.self, from: Data(content[start ..< end].utf8)).arrayValue else { return content }
        return rows.compactMap { row -> String? in
            guard let fields = row.objectValue, let title = fields["title"]?.stringValue,
                  let status = fields["status"]?.stringValue else { return nil }
            return [title + " · " + L10n.chatRunStatus(status), fields["excerpt"]?.stringValue ?? ""]
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// Bound tool payloads independently; keep valid JSON and an explicit truncation marker.
    static func bounded(_ value: JSONValue) throws -> JSONValue {
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count > 65536 else { return value }
        return .object(["truncated": .bool(true), "preview": .string(String(decoding: bytes.prefix(65536), as: UTF8.self))])
    }

    static func assistantItems(_ message: [String: JSONValue]) throws -> [JSONValue] {
        var items = [Self.message(message)]
        for block in message["content"]?.arrayValue?.compactMap(\.objectValue) ?? [] where block["type"]?.stringValue == "toolCall" {
            try items.append(.object([
                "type": .string("tool_call"), "callID": block["id"] ?? .null,
                "name": block["name"] ?? .null, "arguments": bounded(block["arguments"] ?? .null),
            ]))
        }
        return items
    }

    static func toolResult(_ message: [String: JSONValue]) throws -> JSONValue {
        let activity = PiChatService.toolActivity([
            "type": .string("tool_execution_end"), "toolName": message["toolName"] ?? .string("tool"),
            "isError": message["isError"] ?? .bool(false), "result": .object(["content": message["content"] ?? .null]),
        ])
        let status = activity?.status == .inaccessible ? "inaccessible" : message["isError"]?.boolValue == true ? "failed" : "succeeded"
        return try .object([
            "type": .string("tool_result"), "callID": message["toolCallId"] ?? .null,
            "name": message["toolName"] ?? .null,
            "status": .string(status),
            "result": bounded(message["content"] ?? .null),
        ])
    }
}
