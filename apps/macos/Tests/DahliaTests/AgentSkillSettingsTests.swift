#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import Testing
    @testable import Dahlia

    struct AgentSkillSettingsTests {
        @MainActor
        @Test func listsSkillsOnceAndKeepsHistoryForUnavailableSkills() async throws {
            let root = URL(filePath: "/tmp/account-skills")
            let skills = [
                CodexChatSlashCommand(
                    name: "skill:mine",
                    description: "own",
                    source: "skill",
                    sourceInfo: .init(path: root.appending(path: "mine/SKILL.md").path)
                ),
                CodexChatSlashCommand(name: "skill:meeting-reviewer", description: "bundled", source: "skill"),
                CodexChatSlashCommand(
                    name: "skill:installed",
                    description: "package",
                    source: "skill",
                    sourceInfo: .init(path: "/tmp/package/installed/SKILL.md")
                ),
            ]
            let changes = [change("mine"), change("mine"), change("archived"), change("archived"), change("user", kind: "memory")]
            let entries = try await AgentSkillSettingsEntry.grouped(skills: skills, changes: changes, root: root) { file in
                #expect(!Thread.isMainThread)
                return PiSandbox.realPath(file)
            }
            #expect(entries.map(\.name) == ["archived", "installed", "meeting-reviewer", "mine"])
            #expect(entries.filter { !$0.isReadOnly }.map(\.name) == ["archived", "mine"])
            #expect(entries.filter(\.isReadOnly).map(\.name) == ["installed", "meeting-reviewer"])
            #expect(entries.first?.skill == nil)
            #expect(entries.last?.skill?.description == "own")
        }

        @Test func historyOnlySkillCanUnlockAndUndoDeletion() async throws {
            let db = try AppDatabaseManager(path: ":memory:").dbQueue
            let service = AgentSkillService(dbQueue: db)
            let root = URL(filePath: PiSandbox.realPath(FileManager.default.temporaryDirectory)).appending(path: "skill-settings-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let content = "---\nname: sample\ndescription: Use when testing.\n---\nFollow the steps."
            for operation: [String: JSONValue] in [
                ["action": .string("create"), "name": .string("sample"), "content": .string(content)],
                ["action": .string("delete"), "name": .string("sample")],
            ] {
                _ = try await service.execute(
                    "skill_manage", payload: .object(["operations": .array([.object(operation)])]),
                    account: "a", root: root, thread: nil
                )
            }
            let savedChange = try await db.read {
                try AgentLearningChangeRecord.fetchOne($0, sql: "SELECT * FROM agent_learning_changes WHERE after IS NULL")
            }
            let deletion = try #require(savedChange)
            let entries = try await AgentSkillSettingsEntry.grouped(skills: [], changes: [deletion], root: root)
            #expect(entries.map(\.name) == ["sample"])
            try await service.setLocked(name: "sample", account: "a", locked: true)
            #expect(try await service.curationStates(account: "a").first?.locked == true)
            await #expect(throws: (any Error).self) { try await service.undo(id: deletion.id, account: "a", root: root) }
            try await service.setLocked(name: "sample", account: "a", locked: false)
            #expect(try await service.curationStates(account: "a").first?.locked == false)
            try await service.undo(id: deletion.id, account: "a", root: root)
            #expect(try String(contentsOf: root.appending(path: "sample/SKILL.md"), encoding: .utf8) == content)
        }

        @Test func cancelledGroupingStopsBeforeResolvingPathsAndCanRetry() async throws {
            let root = URL(filePath: "/tmp/account-skills")
            let skill = CodexChatSlashCommand(
                name: "skill:mine", description: "own", source: "skill",
                sourceInfo: .init(path: root.appending(path: "mine/SKILL.md").path)
            )
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await AgentSkillSettingsEntry.grouped(skills: [skill], changes: [], root: root) { file in
                    Issue.record("Cancelled grouping must not resolve skill paths")
                    return file.path
                }
            }
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            let retry = try await AgentSkillSettingsEntry.grouped(skills: [skill], changes: [], root: root)
            #expect(retry.map(\.name) == ["mine"])
        }

        private func change(_ target: String, kind: String = "skill") -> AgentLearningChangeRecord {
            AgentLearningChangeRecord(
                id: .v7(), accountID: "a", kind: kind, target: target, status: "applied", source: "review", createdAt: .now
            )
        }
    }
#endif
