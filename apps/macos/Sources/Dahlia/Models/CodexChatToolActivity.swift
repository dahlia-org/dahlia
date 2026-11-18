import DahliaRuntimeSupport
import Foundation

/// Bounded display metadata; complete arguments and output remain in the item log.
struct CodexChatToolActivity: Equatable {
    enum Status: Equatable {
        case running, succeeded, failed, inaccessible
    }

    let name: String
    let status: Status
    var callID: String?
    var detail: String?
    var input: String?
    var output: String?

    var toolSymbol: String {
        switch name.lowercased() {
        case "read": "eye"
        case "bash", "shell", "exec": "terminal"
        case "edit", "write", "apply_patch": "pencil.line"
        case "grep", "find", "ls", "search", "web_search": "magnifyingglass"
        default: "hammer"
        }
    }

    static func displayDetail(_ arguments: JSONValue?) -> String? {
        let fields = arguments?.objectValue ?? [:]
        return ["path", "file_path", "command", "cmd", "query", "pattern"].lazy
            .compactMap { fields[$0]?.stringValue?.nilIfBlank }.first.map { String($0.prefix(240)) }
    }

    /// A call's later event replaces its status and keeps what only the earlier one carried.
    func merging(_ earlier: Self) -> Self {
        var merged = self
        merged.detail = detail ?? earlier.detail
        merged.input = input ?? earlier.input
        merged.output = output ?? earlier.output
        return merged
    }

    /// The command for shells, otherwise the arguments as JSON.
    static func displayInput(_ arguments: JSONValue?) -> String? {
        guard let arguments, arguments != .null else { return nil }
        if let command = arguments.objectValue.flatMap({ $0["command"] ?? $0["cmd"] })?.stringValue {
            return bounded(command, limit: inputLimit)
        }
        return json(arguments).map { bounded($0, limit: inputLimit) }
    }

    /// Text blocks of a tool result, or a saved preview when the stored result was truncated.
    static func displayOutput(_ content: JSONValue?) -> String? {
        guard let content, content != .null else { return nil }
        if let preview = content.objectValue?["preview"]?.stringValue { return bounded(preview, limit: outputLimit) }
        let texts = content.arrayValue?.compactMap { $0.objectValue?["text"]?.stringValue } ?? []
        let text = texts.isEmpty ? content.stringValue ?? json(content) : texts.joined(separator: "\n")
        return text?.nilIfBlank.map { bounded($0, limit: outputLimit) }
    }

    // Bound the display copy without changing the stored payload.
    private static let inputLimit = 4096
    private static let outputLimit = 16384

    private static func bounded(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }

    private static func json(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    var text: String {
        switch status {
        case .running: L10n.chatToolRunning(name)
        case .succeeded: L10n.chatToolSucceeded(name)
        case .failed: L10n.chatToolFailed(name)
        case .inaccessible: L10n.chatToolInaccessible(name)
        }
    }

    var symbol: String {
        switch status {
        case .running: "gearshape"
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .inaccessible: "lock.circle"
        }
    }
}
