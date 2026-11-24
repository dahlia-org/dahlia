import DahliaRuntimeSupport
import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class AgentLearningSettingsModel {
    var memories: [AgentMemoryRecord] = []
    var changes: [AgentLearningChangeRecord] = []
    var changePreviews: [UUID: (before: String?, after: String?)] = [:]
    var schedules: [ChatScheduleRecord] = []
    var scheduleStates: [String: String] = [:]
    var error: String?
    var isBusy = false

    init() {}
    func refresh() async {
        do {
            let memory = try await PiChatService.shared.memoryService()
            let schedule = try await PiChatService.shared.scheduleService()
            let key = AppAccount.key
            let loaded = try await Task.detached {
                let rows = try schedule.list(account: key)
                let states = try schedule.dbQueue.read { db in
                    try Dictionary(uniqueKeysWithValues: rows.map { row in
                        try (
                            row.id,
                            String
                                .fetchOne(
                                    db,
                                    sql: "SELECT status FROM chat_schedule_fires WHERE scheduleID=? ORDER BY createdAt DESC LIMIT 1",
                                    arguments: [row.id]
                                ) ?? "idle"
                        )
                    })
                }
                let changes = try memory.changes(account: key)
                let previews = Dictionary(uniqueKeysWithValues: changes.map { change in
                    (change.id, (
                        before: change.before.map { Self.preview($0, kind: change.kind) },
                        after: change.after.map { Self.preview($0, kind: change.kind) }
                    ))
                })
                return try (memory.entries(account: key), changes, rows, states, previews)
            }.value
            memories = loaded.0
            changes = loaded.1
            schedules = loaded.2
            scheduleStates = loaded.3
            changePreviews = loaded.4
        } catch { self.error = error.localizedDescription }
    }

    nonisolated static func preview(_ value: String, kind: String) -> String {
        let text: String
        var truncated = false
        if kind == "memory", let entry = try? JSONDecoder().decode(AgentMemoryRecord.self, from: Data(value.utf8)) {
            text = entry.content
        } else if kind == "skill", let snapshot = try? JSONDecoder().decode(AgentSkillSnapshot.self, from: Data(value.utf8)) {
            let files = snapshot.files.mapValues { data in
                String(data: data, encoding: .utf8) ?? "(\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))"
            }
            truncated = files.reduce(max(0, files.count - 1) * 2) { $0 + $1.key.count + 1 + $1.value.count } > 12000
            var parts: [String] = []
            var remaining = 12001
            for path in files.keys.sorted() where remaining > 0 {
                let part = String((path + "\n" + (files[path] ?? "")).prefix(remaining))
                parts.append(part)
                remaining -= part.count + 2
            }
            text = parts.joined(separator: "\n\n")
        } else {
            text = value
        }
        return truncated || text.count > 12000 ? String(text.prefix(12000)) + "\n…\n" + L10n.agentLearningPreviewLimit : text
    }

    func saveMemory(target: String, content: String, replacing entry: AgentMemoryRecord?) async {
        await perform {
            let operation: JSONValue = entry
                .map { .object(["action": .string("patch"), "old_text": .string($0.content), "content": .string(content)]) } ?? .object([
                    "action": .string("add"),
                    "content": .string(content),
                ])
            let service = try await PiChatService.shared.memoryService()
            let key = AppAccount.key
            let result = try await Task.detached {
                try service.execute(
                    .object(["target": .string(target), "operations": .array([operation])]),
                    account: key,
                    thread: nil,
                    createdBy: "user"
                )
            }.value
            if result
                .objectValue?["success"] ==
                .bool(false) { throw HermesLearning.failure(result.objectValue?["error"]?.stringValue ?? "Memory update failed.") }
        }
    }

    func remove(_ entries: [AgentMemoryRecord]) async {
        await perform {
            let service = try await PiChatService.shared.memoryService()
            let key = AppAccount.key
            try await Task.detached {
                for target in ["user", "memory"] {
                    let operations = entries.filter { $0.target == target }.map { JSONValue.object([
                        "action": .string("remove"),
                        "old_text": .string($0.content),
                    ])
                    }
                    guard !operations.isEmpty else { continue }
                    let result = try service.execute(
                        .object(["target": .string(target), "operations": .array(operations)]),
                        account: key,
                        thread: nil,
                        createdBy: "user"
                    )
                    if result
                        .objectValue?["success"] ==
                        .bool(false) { throw HermesLearning.failure(result.objectValue?["error"]?.stringValue ?? "Memory update failed.") }
                }
            }.value
        }
    }

    func resolve(_ change: AgentLearningChangeRecord, action: String) async {
        await perform {
            if change.kind == "skill" {
                let service = try await PiChatService.shared.skillService()
                let root = try await PiChatService.shared.skillsRoot()
                if action == "undo" {
                    try await service.undo(id: change.id, account: AppAccount.key, root: root)
                } else {
                    try await service.resolveProposal(id: change.id, account: AppAccount.key, root: root, approve: action == "approve")
                }
            } else {
                let service = try await PiChatService.shared.memoryService()
                let account = AppAccount.key
                try await Task.detached {
                    try service.resolve(id: change.id, account: account, action: action)
                }.value
            }
        }
    }

    func schedule(_ row: ChatScheduleRecord, action: String, approved: Bool = false) async {
        await perform {
            let service = try await PiChatService.shared.scheduleService()
            let account = AppAccount.key
            let tools = try JSONDecoder().decode([String].self, from: Data(row.allowedTools.utf8))
            _ = try await Task.detached {
                try service.execute(
                    .object(["action": .string(action), "job_id": .string(row.id)]),
                    account: account,
                    approved: approved,
                    tools: tools,
                    expectedRevision: row.revision
                )
            }.value
            await PiChatService.shared.drainLearningWork()
        }
    }

    func notification(_ row: ChatScheduleRecord, enabled: Bool) async {
        await perform {
            let service = try await PiChatService.shared.scheduleService()
            let account = AppAccount.key
            try await Task.detached { try service.dbQueue.write {
                try $0.execute(
                    sql: "UPDATE chat_schedules SET notify=? WHERE id=? AND accountID=?",
                    arguments: [enabled, row.id, account]
                )
            }
            }.value
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await operation()
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
}
