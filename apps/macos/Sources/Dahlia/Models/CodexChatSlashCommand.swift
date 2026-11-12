import Foundation

struct CodexChatSlashCommand: Decodable, Identifiable, Equatable, Sendable {
    let name: String
    let description: String?
    let source: String
    var sourceInfo: SourceInfo?

    struct SourceInfo: Decodable, Equatable, Sendable {
        let path: String?
    }

    var id: String { name }

    var displayName: String {
        source == "skill" && name.hasPrefix("skill:") ? String(name.dropFirst("skill:".count)) : name
    }

    var skillFileURL: URL? {
        guard source == "skill", let path = sourceInfo?.path, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

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
