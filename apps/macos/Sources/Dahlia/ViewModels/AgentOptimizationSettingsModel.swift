import Foundation
import GRDB
import Observation

/// Settings → Skills → Auto optimization: archived skills, optimizable skills, and a bounded page of each system task's runs.
@MainActor
@Observable
final class AgentOptimizationSettingsModel {
    static let pageSize = 20
    let account: CodexRuntimeProvider
    static let tasks = ["review", "curator", "optimizer"]
    /// The newest runs of each task (`review`, `curator`, `optimizer`).
    var runs: [String: [AgentSystemRunRecord]] = [:]
    var hasMoreRuns: Set<String> = []
    var archived: [String] = []
    /// Unlocked account skills, the ones the skill optimizer may rewrite.
    var optimizableSkills: [String] = []
    var error: String?
    var isBusy = false
    private var limits: [String: Int] = [:]

    init(account: CodexRuntimeProvider) { self.account = account }

    func refresh() async {
        do {
            let skills = try await PiChatService.shared.skillService()
            let dbQueue = skills.dbQueue
            let key = account.accountKey
            let limits = Dictionary(uniqueKeysWithValues: Self.tasks.map { ($0, self.limits[$0] ?? Self.pageSize) })
            // One extra row tells whether another page exists; the task index keeps this independent of history size.
            let rows = try await dbQueue.read { db in
                var rows: [String: [AgentSystemRunRecord]] = [:]
                for (task, limit) in limits {
                    rows[task] = try AgentSystemRunRecord.fetchAll(
                        db,
                        sql: "SELECT * FROM agent_system_runs WHERE accountID=? AND task=? ORDER BY startedAt DESC, id DESC LIMIT ?",
                        arguments: [key, task, limit + 1]
                    )
                }
                return rows
            }
            runs = Dictionary(uniqueKeysWithValues: rows.map { task, rows in (task, Array(rows.prefix(limits[task] ?? Self.pageSize))) })
            hasMoreRuns = Set(rows.compactMap { task, rows in rows.count > (limits[task] ?? Self.pageSize) ? task : nil })
            let states = try await skills.curationStates(account: key)
            archived = states.filter { $0.state == "archived" }.map(\.name)
            let locked = Set(states.filter(\.locked).map(\.name))
            let root = try await PiChatService.shared.skillsRoot(account)
            optimizableSkills = await Task.detached {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
                return names.filter {
                    AgentSkillService.validName($0) && !locked.contains($0)
                        && FileManager.default.fileExists(atPath: root.appending(path: $0).appending(path: "SKILL.md").path)
                }.sorted()
            }.value
        } catch { self.error = error.localizedDescription }
    }

    func loadMore(_ task: String) async {
        limits[task, default: Self.pageSize] += Self.pageSize
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
