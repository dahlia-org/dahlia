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
