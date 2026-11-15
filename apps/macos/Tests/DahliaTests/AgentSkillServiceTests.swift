#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    struct AgentSkillServiceTests {
        private func setup() throws -> (AgentSkillService, DatabaseQueue, URL) {
            let db = try AppDatabaseManager(path: ":memory:").dbQueue
            let root = URL(fileURLWithPath: PiSandbox.realPath(FileManager.default.temporaryDirectory)).appending(path: "agent-skills-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return (AgentSkillService(dbQueue: db), db, root)
        }

        private let content = "---\nname: sample\ndescription: Use when testing a reusable workflow.\n---\nRead the input and produce a result."
        private func operations(_ values: [[String: JSONValue]]) -> JSONValue { .object(["operations": .array(values.map(JSONValue.object))]) }
        private func create(_ text: String)
            -> [String: JSONValue] { ["action": .string("create"), "name": .string("sample"), "content": .string(text)] }
        @Test func freshReadLockAndUndoPreserveLaterEdits() async throws {
            let (service, db, root) = try setup()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try await service.execute("skill_manage", payload: operations([create(content)]), account: "a", root: root, thread: nil)
            let patch = operations([[
                "name": .string("sample"),
                "action": .string("patch"),
                "old_string": .string("Read the input"),
                "new_string": .string("Validate the input"),
            ]])
            await #expect(throws: (any Error).self) {
                try await service.execute(
                    "skill_manage",
                    payload: patch,
                    account: "a",
                    root: root,
                    thread: nil,
                    review: "r"
                )
            }
            _ = try await service.execute(
                "skill_view",
                payload: .object(["name": .string("sample")]),
                account: "a",
                root: root,
                thread: nil,
                review: "r"
            )
            _ = try await service.execute("skill_manage", payload: patch, account: "a", root: root, thread: nil, review: "r")
            let change = try await db.read {
                try #require(try AgentLearningChangeRecord.fetchOne(
                    $0,
                    sql: "SELECT * FROM agent_learning_changes WHERE reviewID='r'"
                ))
            }
            try await service.undo(id: change.id, account: "a", root: root)
            #expect(try String(contentsOf: root.appending(path: "sample/SKILL.md"), encoding: .utf8) == content)
            try await service.setLocked(name: "sample", account: "a", locked: true)
            await #expect(throws: (any Error).self) {
                try await service.execute("skill_manage", payload: patch, account: "a", root: root, thread: nil)
            }
        }

        @Test func invalidBatchRollsBackAllSkillsAndRejectsTraversal() async throws {
            let (service, _, root) = try setup()
            defer { try? FileManager.default.removeItem(at: root) }
            await #expect(throws: (any Error).self) {
                try await service.execute(
                    "skill_manage",
                    payload: operations([
                        create(content),
                        [
                            "action": .string("write_file"),
                            "name": .string("sample"),
                            "file_path": .string("../auth.json"),
                            "file_content": .string("bad"),
                        ],
                    ]),
                    account: "a",
                    root: root,
                    thread: nil
                )
            }
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "sample").path))
            _ = try await service.execute("skill_manage", payload: operations([create(content)]), account: "a", root: root, thread: nil)
            let invalid = operations([["action": .string("patch"), "name": .string("sample"), "content": .string("missing frontmatter")]])
            await #expect(throws: (any Error).self) {
                try await service.execute(
                    "skill_manage",
                    payload: invalid,
                    account: "a",
                    root: root,
                    thread: nil
                )
            }
            #expect(try String(contentsOf: root.appending(path: "sample/SKILL.md"), encoding: .utf8) == content)
        }

        @Test func packageEditsUndoAndRollbackPreserveBinaryAssetsAndExecutableModes() async throws {
            let (service, db, root) = try setup()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try await service.execute("skill_manage", payload: operations([
                create(content),
                [
                    "action": .string("write_file"),
                    "name": .string("sample"),
                    "file_path": .string("scripts/tool.sh"),
                    "file_content": .string("#!/bin/sh\nexit 0\n"),
                ],
            ]), account: "a", root: root, thread: nil)
            let asset = root.appending(path: "sample/assets/image.png")
            let binary = Data([0x89, 0x50, 0x4E, 0x47, 0, 0xFF, 0x80])
            try FileManager.default.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
            try binary.write(to: asset)
            let script = root.appending(path: "sample/scripts/tool.sh")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let patch = operations([["action": .string("patch"), "name": .string("sample"), "content": .string(content + "\nMore guidance.")]])
            _ = try await service.execute(
                "skill_view",
                payload: .object(["name": .string("sample")]),
                account: "a",
                root: root,
                thread: nil,
                review: "binary-review"
            )
            _ = try await service.execute("skill_manage", payload: patch, account: "a", root: root, thread: nil, review: "binary-review")
            #expect(FileManager.default.isExecutableFile(atPath: script.path))
            #expect(try Data(contentsOf: asset) == binary)
            let changes = AgentMemoryService(dbQueue: db)
            let edit = try #require(try changes.changes(account: "a").first)
            try await service.undo(id: edit.id, account: "a", root: root)
            #expect(FileManager.default.isExecutableFile(atPath: script.path))
            #expect(try Data(contentsOf: asset) == binary)
            _ = try await service.execute(
                "skill_manage",
                payload: operations([["action": .string("delete"), "name": .string("sample")]]),
                account: "a",
                root: root,
                thread: nil
            )
            let deletion = try #require(try changes.changes(account: "a").first)
            #expect(!FileManager.default.fileExists(atPath: script.path))
            #expect(!FileManager.default.fileExists(atPath: asset.path))
            try await service.undo(id: deletion.id, account: "a", root: root)
            #expect(FileManager.default.isExecutableFile(atPath: script.path))
            #expect(try Data(contentsOf: asset) == binary)
            _ = try await service.execute("skill_manage", payload: patch, account: "a", root: root, thread: nil)
            let latest = try #require(try changes.changes(account: "a").first)
            try Data([0xFF, 1]).write(to: asset)
            await #expect(throws: (any Error).self) { try await service.undo(id: latest.id, account: "a", root: root) }
            #expect(try Data(contentsOf: asset) == Data([0xFF, 1]))
            try binary.write(to: asset)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            await #expect(throws: (any Error).self) { try await service.undo(id: latest.id, account: "a", root: root) }
            #expect(try (FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try await db
                .write {
                    try $0
                        .execute(
                            sql: "CREATE TRIGGER fail_skill_ledger BEFORE INSERT ON agent_learning_changes BEGIN SELECT RAISE(ABORT,'test failure'); END"
                        )
                }
            let main = root.appending(path: "sample/SKILL.md")
            let before = try String(contentsOf: main, encoding: .utf8)
            await #expect(throws: (any Error).self) {
                try await service.execute(
                    "skill_manage",
                    payload: operations([["action": .string("patch"), "name": .string("sample"), "content": .string(content + "\nFailed change.")]]),
                    account: "a",
                    root: root,
                    thread: nil
                )
            }
            #expect(try String(contentsOf: main, encoding: .utf8) == before)
            #expect(FileManager.default.isExecutableFile(atPath: script.path))
            #expect(try Data(contentsOf: asset) == binary)
        }

        @Test func externalSkillDeletionRequiresAgentOwnership() async throws {
            let (service, _, root) = try setup()
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appending(path: "sample")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: directory.appending(path: "SKILL.md"))
            _ = try await service.execute(
                "skill_view",
                payload: .object(["name": .string("sample")]),
                account: "a",
                root: root,
                thread: nil,
                review: "r"
            )
            await #expect(throws: (any Error).self) {
                try await service.execute(
                    "skill_manage",
                    payload: operations([["action": .string("delete"), "name": .string("sample")]]),
                    account: "a",
                    root: root,
                    thread: nil,
                    review: "r"
                )
            }
            #expect(FileManager.default.fileExists(atPath: directory.path))
        }
    }
#endif
