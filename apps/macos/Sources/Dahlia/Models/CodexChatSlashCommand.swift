import Foundation

struct CodexChatSlashCommand: Decodable, Identifiable, Equatable, Sendable {
    let name: String
    let description: String?
    let source: String

    var id: String { name }

    static func query(in draft: String) -> String? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }

    static func suggestions(from commands: [Self], query: String) -> [Self] {
        Array(commands.lazy.filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
                || ($0.description?.localizedStandardContains(query) ?? false)
        }.prefix(50))
    }
}
