import DahliaRuntimeSupport
import Foundation

/// Locates Pi runtime resume files and decodes message blocks shared with stored chat history.
enum PiChatSessionFiles {
    static func file(id: String, in directory: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.lastPathComponent.hasSuffix("_\(id).jsonl") }
    }

    /// Rewrites the header's `cwd`, the folder Pi runs the session in, when it names another folder.
    static func setWorkingDirectory(_ directory: URL, in url: URL) throws {
        let data = try Data(contentsOf: url)
        let headerEnd = data.firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
        guard var header = try? JSONDecoder().decode(JSONValue.self, from: data[..<headerEnd]).objectValue,
              header["cwd"]?.stringValue != directory.path else { return }
        header["cwd"] = .string(directory.path)
        try (JSONEncoder().encode(JSONValue.object(header)) + data[headerEnd...]).write(to: url, options: .atomic)
    }

    static func messages(_ records: [[String: JSONValue]]) -> [CodexChatMessage] {
        var messages: [CodexChatMessage] = []
        var assistant: CodexChatMessage?
        func flush() {
            if let assistant, !assistant.text.isEmpty || !assistant.reasoning.isEmpty { messages.append(assistant) }
            assistant = nil
        }
        for record in records where record["type"]?.stringValue == "message" {
            guard let id = record["id"]?.stringValue, let message = record["message"]?.objectValue else { continue }
            let blocks = contentBlocks(message["content"])
            switch message["role"]?.stringValue {
            case "user":
                flush()
                let decoded = CodexChatPromptCodec.decodeTextBlocks([text(blocks, type: "text", key: "text")])
                let images = Array(blocks.compactMap { block -> CodexChatImageAttachment? in
                    guard block["type"]?.stringValue == "image",
                          let data = block["data"]?.stringValue,
                          let mimeType = block["mimeType"]?.stringValue else { return nil }
                    return CodexChatImageAttachment(dataURI: "data:\(mimeType);base64,\(data)")
                }.prefix(CodexChatImageAttachment.maximumAttachmentCount))
                guard decoded.text.nilIfBlank != nil || !images.isEmpty else { continue }
                messages.append(CodexChatMessage(id: id, role: .user, text: decoded.text, context: decoded.context, images: images))
            case "assistant":
                var current = assistant ?? CodexChatMessage(id: id, role: .assistant, text: "")
                current.text = [current.text, text(blocks, type: "text", key: "text")].filter { !$0.isEmpty }.joined(separator: "\n\n")
                current.reasoning = [current.reasoning, text(blocks, type: "thinking", key: "thinking")]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
                assistant = current
            default:
                continue
            }
        }
        flush()
        return messages
    }

    static func text(_ blocks: [[String: JSONValue]], type: String, key: String) -> String {
        blocks.filter { $0["type"]?.stringValue == type }.compactMap { $0[key]?.stringValue }.joined()
    }

    private static func contentBlocks(_ content: JSONValue?) -> [[String: JSONValue]] {
        if let text = content?.stringValue { return [["type": .string("text"), "text": .string(text)]] }
        return content?.arrayValue?.compactMap(\.objectValue) ?? []
    }
}
