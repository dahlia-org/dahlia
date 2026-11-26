import Foundation

struct CodexChatThreadSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let updatedAt: Date
    var parentThreadID: String?
    var status = "idle"
    var isUnread = false
    var firstMessage: String?
    var model: String?
    var requestMessageID: String?
    var requestRunID: UUID?
    var startedAt: Date?
    var completedAt: Date?
    var lastResponseAt: Date?
    var lastItemSeq: Int64?
    var settledAt: Date?

    var hasUnseenCompletion: Bool {
        isUnread && (status == "idle" || status == "completed")
    }

    var modelDisplayName: String? {
        guard let model = model?.nilIfBlank else { return nil }
        var name = model.split(separator: "/").last.map(String.init) ?? model
        if name.hasPrefix("system.ai.") { name = String(name.dropFirst("system.ai.".count)) }
        if name.hasPrefix("claude-") { name = String(name.dropFirst("claude-".count)) }
        return PiProviderConfiguration.displayName(name)
    }

    static func sidebarThreads(_ threads: [Self]) -> [Self] {
        threads.filter { $0.parentThreadID == nil }
    }

    static func treeOrder(_ threads: [Self]) -> [Self] {
        let ids = Set(threads.map(\.id))
        let children = Dictionary(grouping: threads, by: \.parentThreadID)
        return threads.filter { thread in
            thread.parentThreadID.map { !ids.contains($0) } ?? true
        }.flatMap { [$0] + (children[$0.id] ?? []) }
    }
}
