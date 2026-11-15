import Foundation

struct CodexChatThreadSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let updatedAt: Date
    var parentThreadID: String?
    var status = "idle"
    static func treeOrder(_ threads: [Self]) -> [Self] {
        let ids = Set(threads.map(\.id))
        let children = Dictionary(grouping: threads, by: \.parentThreadID)
        return threads.filter { thread in
            thread.parentThreadID.map { !ids.contains($0) } ?? true
        }.flatMap { [$0] + (children[$0.id] ?? []) }
    }
}
