import DahliaRuntimeSupport
import Foundation

/// The memory-compatible envelope stays independent of Pi's resume-file format.
enum ChatHistoryCodec {
    static func message(_ message: [String: JSONValue]) -> JSONValue {
        let blocks = message["content"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let text = message["content"]?.stringValue ?? PiChatSessionFiles.text(blocks, type: "text", key: "text")
        return .object([
            "type": .string("message"), "role": message["role"] ?? .string("assistant"),
            "content": .string(text),
            "reasoning": .string(PiChatSessionFiles.text(blocks, type: "thinking", key: "thinking")),
            "images": .array(blocks.filter { $0["type"]?.stringValue == "image" }.map(JSONValue.object)),
        ])
    }

    static func user(_ inputs: [CodexAppServerInput]) -> JSONValue {
        let prompt = PiRuntimeService.prompt(PiChatService.textJoined(inputs))
        var blocks: [JSONValue] = [.object(["type": .string("text"), "text": prompt["message"] ?? .string("")])]
        blocks += prompt["images"]?.arrayValue ?? []
        return message(["role": .string("user"), "content": .array(blocks)])
    }

    static func messages(_ items: [ChatItemRecord]) throws -> [CodexChatMessage] {
        try messages(items.map(ChatItem.init))
    }

    static func messages(_ items: [ChatItem]) -> [CodexChatMessage] {
        let records = items.compactMap { item -> [String: JSONValue]? in
            guard let data = item.data.objectValue,
                  data["type"]?.stringValue == "message" else { return nil }
            var blocks: [JSONValue] = [.object(["type": .string("text"), "text": data["content"] ?? .string("")])]
            blocks.append(.object(["type": .string("thinking"), "thinking": data["reasoning"] ?? .string("")]))
            blocks += data["images"]?.arrayValue ?? []
            return [
                "type": .string("message"),
                "id": .string(item.id),
                "message": .object(["role": data["role"] ?? .null, "content": .array(blocks)]),
            ]
        }
        return PiChatSessionFiles.messages(records)
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
