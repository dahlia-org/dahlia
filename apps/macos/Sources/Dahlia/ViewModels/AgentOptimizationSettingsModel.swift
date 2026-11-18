import Foundation
import GRDB
import Observation

/// The Auto optimization tab: archived skills and a bounded page of the system-run history.
@MainActor
@Observable
final class AgentOptimizationSettingsModel {
    static let pageSize = 20
    let account: CodexRuntimeProvider
    var runs: [AgentSystemRunRecord] = []
    var hasMoreRuns = false
    var archived: [String] = []
    var error: String?
    var isBusy = false
    private var limit = pageSize

    init(account: CodexRuntimeProvider) { self.account = account }

    func refresh() async {
        do {
            let skills = try await PiChatService.shared.skillService()
            let dbQueue = skills.dbQueue
            let key = account.accountKey
            let limit = limit
            // One extra row tells whether another page exists; the listing index keeps this independent of history size.
            let rows = try await dbQueue.read { db in
                try AgentSystemRunRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM agent_system_runs WHERE accountID=? ORDER BY startedAt DESC, id DESC LIMIT ?",
                    arguments: [key, limit + 1]
                )
            }
            runs = Array(rows.prefix(limit))
            hasMoreRuns = rows.count > limit
            archived = try await skills.curationStates(account: key).filter { $0.state == "archived" }.map(\.name)
        } catch { self.error = error.localizedDescription }
    }

    func loadMore() async {
        limit += Self.pageSize
        await refresh()
    }

    func restore(_ name: String) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            let service = try await PiChatService.shared.skillService()
            let root = try await PiChatService.shared.skillsRoot(account)
            try await service.restore(name: name, account: account.accountKey, root: root)
        } catch { self.error = error.localizedDescription }
        await refresh()
    }
}
