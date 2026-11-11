import DahliaRuntimeSupport
import Foundation

/// Reads Pi session files (`<timestamp>_<id>.jsonl`) without starting Pi.
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

    /// Newest first. The cursor is the last listed thread's modification time and file name, so a thread that
    /// becomes newer between pages is not listed twice and does not push another one out.
    static func page(in directory: URL, cursor: String?, limit: Int) throws -> CodexChatThreadPage {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter { $0.pathExtension == "jsonl" }
        let dated = files.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url: url, key: (date.timeIntervalSince1970, url.lastPathComponent))
        }.sorted { $0.key > $1.key }
        let remaining = cursorKey(cursor).map { after in dated.filter { $0.key < after } } ?? dated
        let slice = remaining.prefix(limit)
        let threads = slice.compactMap { entry -> CodexChatThreadSummary? in
            guard let records = try? summaryRecords(at: entry.url), let id = sessionID(records) else { return nil }
            return CodexChatThreadSummary(id: id, title: title(records), updatedAt: Date(timeIntervalSince1970: entry.key.0))
        }
        let next = remaining.count > limit ? slice.last.map { "\($0.key.0)|\($0.key.1)" } : nil
        return CodexChatThreadPage(threads: threads, nextCursor: next)
    }

    private static func cursorKey(_ cursor: String?) -> (Double, String)? {
        guard let cursor, let separator = cursor.firstIndex(of: "|"), let time = Double(cursor[..<separator]) else { return nil }
        return (time, String(cursor[cursor.index(after: separator)...]))
    }

    static func thread(at url: URL) throws -> CodexChatThread {
        let records = try records(at: url)
        guard let id = sessionID(records) else { throw CodexAppServerError.invalidProtocolResponse }
        var model: String?
        var effort: String?
        for record in records {
            switch record["type"]?.stringValue {
            case "model_change":
                if let provider = record["provider"]?.stringValue, let modelID = record["modelId"]?.stringValue {
                    model = "\(provider)/\(modelID)"
                }
            case "thinking_level_change":
                // Dahlia names Pi's `off` level `none`, as in PiProviderConfiguration.reasoningEfforts.
                effort = record["thinkingLevel"]?.stringValue.map { $0 == "off" ? "none" : $0 }
            default:
                continue
            }
        }
        return CodexChatThread(id: id, title: title(records), messages: messages(records), model: model, reasoningEffort: effort)
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

    /// The header, session names, and the first user message: enough for a title without decoding image and tool output.
    private static func summaryRecords(at url: URL) throws -> [[String: JSONValue]] {
        var records: [[String: JSONValue]] = []
        var foundUserMessage = false
        for (index, line) in try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")).enumerated() {
            let isSessionName = line.firstRange(of: Data(#""type":"session_info""#.utf8)) != nil
            let isUserMessage = !foundUserMessage && line.firstRange(of: Data(#""role":"user""#.utf8)) != nil
            guard index == 0 || isSessionName || isUserMessage,
                  let record = try? JSONDecoder().decode(JSONValue.self, from: Data(line)).objectValue else { continue }
            foundUserMessage = foundUserMessage || isUserMessage
            records.append(record)
        }
        return records
    }

    private static func records(at url: URL) throws -> [[String: JSONValue]] {
        try Data(contentsOf: url).split(separator: UInt8(ascii: "\n")).compactMap {
            try? JSONDecoder().decode(JSONValue.self, from: Data($0)).objectValue
        }
    }

    private static func sessionID(_ records: [[String: JSONValue]]) -> String? {
        guard let header = records.first, header["type"]?.stringValue == "session" else { return nil }
        return header["id"]?.stringValue
    }

    /// The latest session name, or the first user message's visible text.
    private static func title(_ records: [[String: JSONValue]]) -> String {
        if let name = records.last(where: { $0["type"]?.stringValue == "session_info" })?["name"]?.stringValue?.nilIfBlank {
            return name
        }
        for record in records where record["type"]?.stringValue == "message" {
            guard let message = record["message"]?.objectValue, message["role"]?.stringValue == "user" else { continue }
            let visible = CodexChatPromptCodec.visibleUserText(from: text(contentBlocks(message["content"]), type: "text", key: "text"))
            if let line = visible.split(whereSeparator: \.isNewline).first { return String(line.prefix(120)) }
        }
        return ""
    }
}
