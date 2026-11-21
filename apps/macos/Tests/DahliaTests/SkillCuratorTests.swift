#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import os
    import Testing
    @testable import Dahlia

    struct SkillCuratorTests {
        private let now = Date(timeIntervalSince1970: 1_800_000_000)

        private func setup() throws -> (AgentSkillService, any DatabaseWriter, URL) {
            let db = try AppDatabaseManager(path: ":memory:").dbQueue
            let root = URL(fileURLWithPath: PiSandbox.realPath(FileManager.default.temporaryDirectory)).appending(path: "curator-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return (AgentSkillService(dbQueue: db), db, root)
        }

        private func skill(_ name: String) -> String {
            "---\nname: \(name)\ndescription: Use when testing \(name).\n---\nFollow the steps."
        }

        /// A Curator-managed skill on disk whose newest activity was `daysAgo` days before `now`.
        private func managed(
            _ name: String,
            daysAgo: Double?,
            uses: Int = 1,
            createdBy: String = "agent",
            state: String = "active",
            pinned: Bool = false,
            locked: Bool = false,
            db: any DatabaseWriter,
            root: URL
        ) throws {
            let directory = root.appending(path: name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(skill(name).utf8).write(to: directory.appending(path: "SKILL.md"))
            let activity = daysAgo.map { now.addingTimeInterval(-$0 * 86400) }
            try db.write {
                try $0.execute(
                    sql: """
                    INSERT OR REPLACE INTO agent_skill_states(accountID,name,createdBy,locked,pinned,state,useCount,lastUsedAt,createdAt)
                    VALUES('a',?,?,?,?,?,?,?,?)
                    """,
                    arguments: [name, createdBy, locked, pinned, state, uses, activity, activity ?? now.addingTimeInterval(-400 * 86400)]
                )
            }
        }

        private func state(_ name: String, _ db: any DatabaseWriter) throws -> String? {
            try db.read { try String.fetchOne($0, sql: "SELECT state FROM agent_skill_states WHERE name=?", arguments: [name]) }
        }

        @Test func migrationKeepsLocksAndLeavesExistingSkillsUncurated() throws {
            let db = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(db, upTo: "v65_chatRunPresentation")
            try db.write { db in
                for (name, source) in [("reviewed", "review"), ("asked", "interactive")] {
                    try db.execute(
                        sql: "INSERT INTO agent_skill_states(accountID,name,createdBy,locked) VALUES('a',?,'agent',?)",
                        arguments: [name, name == "asked"]
                    )
                    try db.execute(
                        sql: """
                        INSERT INTO agent_learning_changes(id,accountID,kind,target,before,after,status,source,createdAt)
                        VALUES(?,'a','skill',?,NULL,'{}','applied',?,?)
                        """,
                        arguments: [UUID.v7(), name, source, Date()]
                    )
                }
            }
            try AppDatabaseManager.migrator.migrate(db)
            try db.read { db throws in
                let rows = try Row.fetchAll(db, sql: "SELECT name,createdBy,locked,state,useCount,createdAt FROM agent_skill_states ORDER BY name")
                #expect(rows.map { $0["createdBy"] as String } == ["user", "user"])
                #expect(rows.map { $0["locked"] as Bool } == [true, false])
                #expect(rows.allSatisfy { $0["state"] == "active" && $0["useCount"] == 0 && ($0["createdAt"] as Date?) == nil })
                #expect(try db.tableExists("agent_system_runs"))
                #expect(try AppDatabaseManager.hasExpectedCurrentSchema(db))
            }
        }

        @Test func transitionsFollowUpstreamAndSkipProtectedSkills() async throws {
            let (service, db, root) = try setup()
            defer { try? FileManager.default.removeItem(at: root) }
            try managed("recent", daysAgo: 3, db: db, root: root)
            try managed("idle", daysAgo: 20, db: db, root: root)
            try managed("old", daysAgo: 40, db: db, root: root)
            try managed("fresh-unused", daysAgo: nil, uses: 0, db: db, root: root)
            let now = now
            try await db.write { try $0.execute(sql: "UPDATE agent_skill_states SET createdAt=? WHERE name='fresh-unused'", arguments: [now]) }
            try managed("back", daysAgo: 2, state: "stale", db: db, root: root)
            try managed("pinned", daysAgo: 90, pinned: true, db: db, root: root)
            try managed("locked", daysAgo: 90, locked: true, db: db, root: root)
            try managed("asked", daysAgo: 90, createdBy: "learn", db: db, root: root)
            try managed("scheduled", daysAgo: 90, db: db, root: root)
            try managed("skill-creator", daysAgo: 90, db: db, root: root)
            try managed("legacy", daysAgo: 90, db: db, root: root)
            try await db.write { db in
                try db.execute(sql: "UPDATE agent_skill_states SET createdAt=NULL WHERE name='legacy'")
                let thread = UUID().uuidString
                try db.execute(
                    sql: "INSERT INTO chat_threads(id,accountID,title,createdAt,updatedAt) VALUES(?,'a','t',?,?)",
                    arguments: [thread, Date(), Date()]
                )
                try db.execute(
                    sql: """
                    INSERT INTO chat_schedules(id,accountID,threadID,name,schedule,prompt,skills,allowedTools,revision,enabled,createdAt,updatedAt)
                    VALUES('s','a',?,'n','every 1d','p','["scheduled"]','[]',1,1,?,?)
                    """,
                    arguments: [thread, Date(), Date()]
                )
            }

            let counts = try await service.applyCuratorTransitions(
                account: "a", root: root, now: now, staleAfterDays: 14, archiveAfterDays: 30
            )

            #expect(counts == SkillCuratorCounts(checked: 9, markedStale: 1, archived: 1, reactivated: 1, seeded: 1))
            #expect(try state("recent", db) == "active")
            #expect(try state("idle", db) == "stale")
            #expect(try state("old", db) == "archived")
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "old").path))
            #expect(FileManager.default.fileExists(atPath: root.appending(path: ".archive/old/SKILL.md").path))
            #expect(try state("fresh-unused", db) == "active")
            #expect(try state("back", db) == "active")
            for name in ["pinned", "locked", "asked", "scheduled", "skill-creator", "legacy"] {
                #expect(FileManager.default.fileExists(atPath: root.appending(path: name).path), "\(name)")
            }
            let seeded = try await db.read { try Date.fetchOne($0, sql: "SELECT createdAt FROM agent_skill_states WHERE name='legacy'") }
            #expect(seeded == now)

            let candidates = try #require(try await service.curatorCandidates(account: "a", root: root))
            #expect(candidates.hasPrefix("Agent-created skills ("))
            #expect(candidates.contains("- scheduled  provenance=agent  state=active  pinned=no  cron=yes  activity=1  use=1"))
            #expect(!candidates.contains("- old ") && !candidates.contains("- asked ") && !candidates.contains("- skill-creator "))
        }

        @Test func archiveIsRecoverableAndRestoreTakesTheExactNameFirst() async throws {
            let (service, db, root) = try setup()
            defer { try? FileManager.default.removeItem(at: root) }
            try managed("sample", daysAgo: 1, db: db, root: root)
            try await service.archive(name: "sample", account: "a", root: root)
            try managed("sample", daysAgo: 1, db: db, root: root)
            try Data("second".utf8).write(to: root.appending(path: "sample/marker"))
            try await service.archive(name: "sample", account: "a", root: root)
            let archived = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: ".archive").path).sorted()
            #expect(archived.count == 2 && archived[0] == "sample" && archived[1].hasPrefix("sample-"))

            try await service.restore(name: "sample", account: "a", root: root)
            #expect(try state("sample", db) == "active")
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "sample/marker").path))
            await #expect(throws: (any Error).self) { try await service.restore(name: "sample", account: "a", root: root) }
            await #expect(throws: (any Error).self) { try await service.archive(name: "skill-creator", account: "a", root: root) }
        }

        @Test func restoreRespectsLockAndCanRetryAfterUnlock() async throws {
            let (service, db, root) = try setup()
            defer { try? FileManager.default.removeItem(at: root) }
            try managed("sample", daysAgo: 40, db: db, root: root)
            try await service.archive(name: "sample", account: "a", root: root)
            try await service.setLocked(name: "sample", account: "a", locked: true)
            await #expect(throws: (any Error).self) { try await service.restore(name: "sample", account: "a", root: root) }
            #expect(try state("sample", db) == "archived")
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "sample").path))
            #expect(FileManager.default.fileExists(atPath: root.appending(path: ".archive/sample/SKILL.md").path))
            try await service.setLocked(name: "sample", account: "a", locked: false)
            try await service.restore(name: "sample", account: "a", root: root)
            #expect(try state("sample", db) == "active")
            #expect(try String(contentsOf: root.appending(path: "sample/SKILL.md"), encoding: .utf8) == skill("sample"))
        }

        @Test func usageAndProvenanceAreRecordedThroughSkillTools() async throws {
            let (service, db, root) = try setup()
            defer { try? FileManager.default.removeItem(at: root) }
            func manage(_ op: [String: JSONValue], review: String? = nil) async throws {
                _ = try await service.execute(
                    "skill_manage", payload: .object(["operations": .array([.object(op)])]), account: "a", root: root, thread: nil, review: review
                )
            }
            try await manage(["action": .string("create"), "name": .string("asked"), "content": .string(skill("asked"))])
            try await manage(["action": .string("create"), "name": .string("learned"), "content": .string(skill("learned"))], review: "r")
            _ = try await service.execute(
                "skill_view", payload: .object(["name": .string("learned")]), account: "a", root: root, thread: nil, review: "r"
            )
            _ = try await service.execute(
                "skill_view", payload: .object(["name": .string("learned")]), account: "a", root: root, thread: nil, review: "c", curator: true
            )
            try await manage(
                ["action": .string("patch"), "name": .string("learned"), "old_string": .string("Follow"), "new_string": .string("Run")], review: "r"
            )
            await service.recordRead(path: root.appending(path: "asked/SKILL.md").path, account: "a", root: root)
            let (owners, counts) = try await db.read { db in
                let rows = try Row.fetchAll(db, sql: "SELECT name,createdBy,useCount,viewCount,patchCount FROM agent_skill_states ORDER BY name")
                return (
                    rows.map { [$0["name"], $0["createdBy"]] as [String] },
                    rows.map { [$0["useCount"], $0["viewCount"], $0["patchCount"]] as [Int] }
                )
            }
            #expect(owners == [["asked", "learn"], ["learned", "agent"]])
            #expect(counts == [[1, 0, 0], [1, 1, 1]])
            #expect(SkillProvenance.of(name: "skill-creator", file: nil, root: root) == .bundled)
            #expect(SkillProvenance.of(name: "x", file: URL(filePath: "/elsewhere/x/SKILL.md"), root: root) == .package)
            #expect(SkillProvenance.of(name: "x", file: root.appending(path: "x/SKILL.md"), root: root) == .account)
        }

        @Test func backgroundDeletesNeedAnUmbrellaAndArchivePinnedSkillsNever() async throws {
            let (service, db, root) = try setup()
            defer { try? FileManager.default.removeItem(at: root) }
            try managed("narrow", daysAgo: 1, db: db, root: root)
            try managed("umbrella", daysAgo: 1, db: db, root: root)
            func view(_ name: String) async throws {
                _ = try await service.execute(
                    "skill_view", payload: .object(["name": .string(name)]), account: "a", root: root, thread: nil, review: "c", curator: true
                )
            }
            func delete(_ name: String, into target: String?, review: String? = "c") async throws {
                var op: [String: JSONValue] = ["action": .string("delete"), "name": .string(name)]
                op["absorbed_into"] = target.map(JSONValue.string)
                _ = try await service.execute(
                    "skill_manage", payload: .object(["operations": .array([.object(op)])]), account: "a", root: root, thread: nil,
                    review: review, curator: review != nil
                )
            }
            try await view("narrow")
            await #expect(throws: (any Error).self) { try await delete("narrow", into: nil) }
            await #expect(throws: (any Error).self) { try await delete("narrow", into: "missing") }
            await #expect(throws: (any Error).self) { try await delete("narrow", into: "narrow") }
            try await delete("narrow", into: "umbrella")
            #expect(try state("narrow", db) == "archived")
            #expect(FileManager.default.fileExists(atPath: root.appending(path: ".archive/narrow/SKILL.md").path))
            let archivedChange = try #require(try await db.read { try AgentLearningChangeRecord.fetchOne($0) })
            #expect(archivedChange.source == "curator" && archivedChange.reviewID == "c")
            try await service.undo(id: archivedChange.id, account: "a", root: root)
            #expect(try state("narrow", db) == "active")

            try await service.setPinned(name: "umbrella", account: "a", pinned: true)
            await #expect(throws: (any Error).self) { try await delete("umbrella", into: nil, review: nil) }
            #expect(FileManager.default.fileExists(atPath: root.appending(path: "umbrella/SKILL.md").path))
        }

        @Test func autonomousArchiveIsLoggedAndUndoRestoresTheSkillState() async throws {
            let (service, db, root) = try setup()
            defer { try? FileManager.default.removeItem(at: root) }
            try managed("sample", daysAgo: 40, db: db, root: root)
            try await service.archive(name: "sample", account: "a", root: root, source: "review", review: "r")
            let change = try #require(try await db.read { try AgentLearningChangeRecord.fetchOne($0) })
            #expect(change.source == "review" && change.reviewID == "r" && change.after == nil)
            #expect(change.before != nil && change.status == "applied")
            try await service.undo(id: change.id, account: "a", root: root)
            #expect(try state("sample", db) == "active")
            #expect(try String(contentsOf: root.appending(path: "sample/SKILL.md"), encoding: .utf8) == skill("sample"))
            #expect(try await db.read { try AgentLearningChangeRecord.fetchOne($0, key: change.id)?.status } == "reverted")
            // The separate Restore path must still refuse to replace the recovered package.
            await #expect(throws: (any Error).self) { try await service.restore(name: "sample", account: "a", root: root) }
        }

        @Test func curatorEditsEnforceEligibilityWithoutRestrictingInteractiveEdits() async throws {
            let (service, db, root) = try setup()
            defer { try? FileManager.default.removeItem(at: root) }
            try await db.write { db in
                let thread = UUID.v7().uuidString
                try db.execute(
                    sql: "INSERT INTO chat_threads(id,accountID,title,createdAt,updatedAt) VALUES(?,'a','t',?,?)",
                    arguments: [thread, Date(), Date()]
                )
                try db.execute(sql: """
                INSERT INTO chat_schedules(id,accountID,threadID,name,schedule,prompt,skills,allowedTools,revision,enabled,createdAt,updatedAt)
                VALUES('s','a',?,'n','every 1d','p','["scheduled"]','[]',1,1,?,?)
                """, arguments: [thread, Date(), Date()])
            }
            for (name, owner, pinned) in [
                ("manual", "user", false),
                ("asked", "learn", false),
                ("pinned", "agent", true),
                ("scheduled", "agent", false),
            ] {
                try managed(name, daysAgo: 1, createdBy: owner, pinned: pinned, db: db, root: root)
                _ = try await service.execute(
                    "skill_view", payload: .object(["name": .string(name)]), account: "a", root: root, thread: nil, review: "c", curator: true
                )
                try FileManager.default.createDirectory(at: root.appending(path: "\(name)/references"), withIntermediateDirectories: true)
                try Data("old".utf8).write(to: root.appending(path: "\(name)/references/old.md"))
                _ = try await service.execute(
                    "skill_view", payload: .object(["name": .string(name), "file_path": .string("references/old.md")]),
                    account: "a", root: root, thread: nil, review: "c", curator: true
                )
                for operation: [String: JSONValue] in [
                    ["action": .string("patch"), "name": .string(name), "old_string": .string("Follow"), "new_string": .string("Run")],
                    [
                        "action": .string("write_file"),
                        "name": .string(name),
                        "file_path": .string("references/new.md"),
                        "file_content": .string("new"),
                    ],
                    ["action": .string("remove_file"), "name": .string(name), "file_path": .string("references/old.md")],
                ] {
                    await #expect(throws: (any Error).self) {
                        try await service.execute(
                            "skill_manage", payload: .object(["operations": .array([.object(operation)])]),
                            account: "a", root: root, thread: nil, review: "c", curator: true
                        )
                    }
                }
                #expect(try String(contentsOf: root.appending(path: "\(name)/SKILL.md"), encoding: .utf8) == skill(name))
                _ = try await service.execute(
                    "skill_manage", payload: .object(["operations": .array([.object([
                        "action": .string("patch"), "name": .string(name), "old_string": .string("Follow"), "new_string": .string("Run"),
                    ])])]), account: "a", root: root, thread: nil
                )
            }
            // A protection change after skill_view must be checked at mutation, not cached at discovery.
            try managed("changed", daysAgo: 1, db: db, root: root)
            _ = try await service.execute(
                "skill_view", payload: .object(["name": .string("changed")]), account: "a", root: root, thread: nil, review: "c", curator: true
            )
            try await service.setPinned(name: "changed", account: "a", pinned: true)
            await #expect(throws: (any Error).self) {
                try await service.execute(
                    "skill_manage", payload: .object(["operations": .array([.object([
                        "action": .string("patch"), "name": .string("changed"), "old_string": .string("Follow"), "new_string": .string("Run"),
                    ])])]), account: "a", root: root, thread: nil, review: "c", curator: true
                )
            }
        }

        @Test(arguments: [20.0, 40.0])
        func transitionsRecheckAuthorizationAtMutationAndCanRetry(daysAgo: Double) async throws {
            let (service, db, root) = try setup()
            defer { try? FileManager.default.removeItem(at: root) }
            try managed("sample", daysAgo: daysAgo, db: db, root: root)
            let checks = OSAllocatedUnfairLock(initialState: 0)
            await #expect(throws: CancellationError.self) {
                try await service.applyCuratorTransitions(account: "a", root: root, now: now, staleAfterDays: 14, archiveAfterDays: 30) { _ in
                    let count = checks.withLock { $0 += 1
                        return $0
                    }
                    if count > 1 { throw CancellationError() }
                }
            }
            #expect(try state("sample", db) == "active")
            #expect(FileManager.default.fileExists(atPath: root.appending(path: "sample/SKILL.md").path))
            #expect(try await db.read { try AgentLearningChangeRecord.fetchCount($0) } == 0)
            _ = try await service.applyCuratorTransitions(account: "a", root: root, now: now, staleAfterDays: 14, archiveAfterDays: 30)
            #expect(try state("sample", db) == (daysAgo == 40 ? "archived" : "stale"))
        }

        @Test func indexRankPutsRecentActivityFirstAndSkipsArchivedSkills() async throws {
            let (service, db, root) = try setup()
            try managed("old", daysAgo: 30, db: db, root: root)
            try managed("recent", daysAgo: 1, db: db, root: root)
            try managed("viewed", daysAgo: 60, db: db, root: root)
            try managed("archived", daysAgo: 0, state: "archived", db: db, root: root)
            try await db.write {
                try $0.execute(sql: "UPDATE agent_skill_states SET lastViewedAt=? WHERE name='viewed'", arguments: [now])
                try $0.execute(sql: "INSERT INTO agent_skill_states(accountID,name,createdBy,locked) VALUES('b','other','user',0)")
            }
            let rank = try await service.indexRank(account: "a")
            #expect(rank == ["viewed", "recent", "old"])
        }

        @Test func retentionKeepsTheNewestRunOfEachTask() throws {
            let db = try AppDatabaseManager(path: ":memory:").dbQueue
            try db.write { db in
                for (id, task, days, status) in [
                    ("old-curator", "curator", 60.0, "completed"), ("older-curator", "curator", 90.0, "completed"),
                    ("old-review", "review", 45.0, "completed"), ("new-review", "review", 1.0, "completed"),
                    ("stuck", "review", 70.0, "running"),
                ] {
                    try AgentSystemRunRecord(
                        id: id, accountID: "a", task: task, status: status, summary: "", report: "",
                        startedAt: now.addingTimeInterval(-days * 86400)
                    ).insert(db)
                }
                try AgentSystemRunRecord.deleteExpired(db, before: now.addingTimeInterval(-30 * 86400))
                #expect(try String.fetchAll(db, sql: "SELECT id FROM agent_system_runs ORDER BY id") == ["new-review", "old-curator", "stuck"])
            }
        }

        @Test func reviewKindsFollowTheSplitSwitches() {
            let account = "curator-test-\(UUID())"
            let defaults = UserDefaults.standard
            let keys = [
                AgentLearningSettings.legacyReviewKey(account), AgentLearningSettings.skillReviewKey(account),
                AgentLearningSettings.memoryReviewKey(account), AgentLearningSettings.memoryKey(account),
            ]
            defer { keys.forEach(defaults.removeObject(forKey:)) }
            #expect(PiChatService.effectiveReviewKind("combined", account: account) == "combined")
            defaults.set(false, forKey: AgentLearningSettings.legacyReviewKey(account))
            #expect(PiChatService.effectiveReviewKind("combined", account: account) == nil)
            defaults.set(true, forKey: AgentLearningSettings.skillReviewKey(account))
            #expect(PiChatService.effectiveReviewKind("combined", account: account) == "skill")
            #expect(PiChatService.effectiveReviewKind("memory", account: account) == nil)
            defaults.set(true, forKey: AgentLearningSettings.memoryReviewKey(account))
            defaults.set(false, forKey: AgentLearningSettings.memoryKey(account))
            #expect(PiChatService.effectiveReviewKind("combined", account: account) == "skill")
        }

        @Test func upstreamCuratorPromptIsVendoredUnchanged() {
            #expect(HermesLearning.count(HermesLearning.prompts["curator_review_prompt"] ?? "") == 10300)
        }

        @Test func housekeepingRunsEachChoreOnItsOwnTicks() {
            let chore = Housekeeping.Chore(name: "c", everyTicks: 60, firstTick: 2) {}
            #expect((0 ..< 200).filter { Housekeeping.isDue(chore, at: $0) } == [2, 62, 122, 182])
        }
    }
#endif
