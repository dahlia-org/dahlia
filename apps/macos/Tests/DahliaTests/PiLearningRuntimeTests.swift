#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import GRDB
    import os
    import Testing
    @testable import Dahlia

    struct PiLearningRuntimeTests {
        private func store() throws -> ChatThreadStore {
            let db = try AppDatabaseManager(path: ":memory:").dbQueue
            return ChatThreadStore(dbQueue: db)
        }

        @Test func completeSnapshotKeepsProvenanceAndNotifiesOnce() async throws {
            let store = try store()
            let thread = UUID.v7().uuidString
            var record = ChatThreadRecord(id: thread, accountID: "synthetic", title: "test", createdAt: .now, updatedAt: .now)
            record.memoryTurns = 10
            try store.createThread(
                record,
                items: [.object(["type": .string("message"), "role": .string("user"), "content": .string("unknown origin")])]
            )
            let userID = UUID.v7()
            let user = try store.enqueueRun(ChatRunRecord(
                id: userID,
                threadID: thread,
                rootRunID: userID,
                status: "completed",
                input: "",
                effort: "medium",
                approvalMethod: "ask",
                createdAt: .now
            ))
            try store.appendItems(
                threadID: thread,
                items: [.object(["type": .string("message"), "role": .string("user"), "content": .string("human statement")])],
                runID: user.id
            )
            let machine = try store.enqueueRun(ChatRunRecord(
                id: .v7(),
                threadID: thread,
                rootRunID: userID,
                status: "completed",
                input: "",
                effort: "medium",
                approvalMethod: "ask",
                createdAt: .now
            ))
            try store.appendItems(
                threadID: thread,
                items: [.object(["type": .string("message"), "role": .string("user"), "content": .string("machine statement")])],
                runID: machine.id
            )
            let chat = PiChatService(historyStore: store)
            try await chat.enqueueReview(user, account: "synthetic")
            let job = try await store.dbQueue.read { db in
                try #require(try AgentReviewRecord.fetchOne(db, sql: "SELECT * FROM agent_reviews"))
            }
            #expect(job.snapshot.contains("unknown origin") && job.snapshot.contains("human statement") && job.snapshot.contains("machine statement"))
            #expect(job.snapshot.contains("machine-or-unknown") && job.snapshot.contains("user-conversation"))
            #expect(try store.thread(id: thread, accountID: "synthetic").memoryTurns == 0)
            let memory = AgentMemoryService(dbQueue: store.dbQueue)
            _ = try memory.execute(
                .object([
                    "target": .string("user"),
                    "operations": .array([.object(["action": .string("add"), "content": .string("User prefers Japanese")])]),
                ]),
                account: "synthetic",
                thread: thread,
                review: job.id
            )
            // A review finishing during the next user run must not acquire that run's provenance.
            let activeID = UUID.v7()
            _ = try store.enqueueRun(ChatRunRecord(
                id: activeID,
                threadID: thread,
                rootRunID: activeID,
                status: "running",
                input: "",
                effort: "medium",
                approvalMethod: "ask",
                createdAt: .now
            ))
            try await chat.finishReview(job, status: "completed")
            try await chat.finishReview(job, status: "completed")
            let notifications = try store.listItems(threadID: thread).filter { $0.data.contains("review_id") }
            #expect(notifications.count == 1)
            #expect(notifications.first?.runID == nil)
            let saved = try await store.dbQueue.read { try AgentReviewRecord.fetchOne($0, key: job.id) }
            #expect(saved?.snapshot.isEmpty == true && saved?.notified == true)
        }

        @Test func disabledReviewLaunchOmitsOnlyFrozenMemoryInjection() {
            let snapshot = PiChatService.ReviewSnapshot(
                conversation: "history",
                arguments: ["--system-prompt", "base", "--append-system-prompt", "custom"],
                environment: [:],
                memoryPrompt: "frozen memory"
            )
            #expect(snapshot.launchArguments(memoryEnabled: false) == snapshot.arguments)
            #expect(snapshot.launchArguments(memoryEnabled: true) == snapshot.arguments + ["--append-system-prompt", "frozen memory"])
        }

        @Test func reviewLaunchRechecksMemorySettingBeforeCreatingTheProcess() async throws {
            let provider = CodexRuntimeProvider.databricks(connectionID: .v7())
            let pi = TestPiRuntime(provider: provider) { _ in TestPiTransport() }
            let key = AgentLearningSettings.memoryKey(provider.accountKey)
            UserDefaults.standard.set(false, forKey: key)
            defer {
                UserDefaults.standard.removeObject(forKey: key)
                try? FileManager.default.removeItem(at: pi.rootURL)
            }
            await #expect(throws: (any Error).self) {
                try await pi.service.connect(
                    .init(mode: .chat, cwd: pi.rootURL, environment: ["DAHLIA_PI_MEMORY_ENABLED": "1"], profile: .review),
                    provider: provider
                )
            }
            #expect(pi.launches.all.isEmpty)
            await pi.service.shutdown()
        }

        @Test func reviewAuthorizationRejectsStaleAndCrossAccountPublications() async throws {
            let pi = TestPiRuntime { _ in TestPiTransport() }
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            let store = try store()
            let thread = UUID.v7().uuidString
            try store.createThread(ChatThreadRecord(id: thread, accountID: "local", title: "test", createdAt: .now, updatedAt: .now))
            let review = AgentReviewRecord(
                id: UUID.v7().uuidString,
                accountID: "local",
                threadID: thread,
                kind: "combined",
                snapshot: "",
                effort: "medium",
                status: "running",
                createdAt: .now
            )
            try await store.dbQueue.write { try review.insert($0) }
            let authorize = PiChatService.reviewAuthorization(review, provider: .local, runtime: pi.service)
            try await store.dbQueue.read { try authorize($0) }
            try await store.dbQueue.write { try $0.execute(sql: "UPDATE agent_reviews SET status='cancelled' WHERE id=?", arguments: [review.id]) }
            let memory = AgentMemoryService(dbQueue: store.dbQueue)
            let payload: JSONValue = .object([
                "target": .string("user"),
                "operations": .array([.object(["action": .string("add"), "content": .string("Must not be saved")])]),
            ])
            let result = try memory.execute(payload, account: "local", thread: thread, review: review.id, authorize: authorize)
            #expect(result.objectValue?["success"] == .bool(false))
            #expect(try memory.entries(account: "local").isEmpty)
            let skills = AgentSkillService(dbQueue: store.dbQueue)
            let root = URL(filePath: PiSandbox.realPath(pi.rootURL)).appending(path: "managed-skills")
            let create: JSONValue = .object(["operations": .array([.object([
                "action": .string("create"),
                "name": .string("sample"),
                "content": .string("---\nname: sample\ndescription: A test skill.\n---\nFollow the workflow."),
            ])])])
            await #expect(throws: (any Error).self) {
                try await skills.execute(
                    "skill_manage",
                    payload: create,
                    account: "local",
                    root: root,
                    thread: thread,
                    review: review.id,
                    authorize: authorize
                )
            }
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "sample").path))
            #expect(try memory.changes(account: "local").isEmpty)
            try await store.dbQueue.write { try $0.execute(sql: "UPDATE agent_reviews SET status='running' WHERE id=?", arguments: [review.id]) }
            pi.contextStore.beginActivation(.databricks(connectionID: .v7()))
            await #expect(throws: (any Error).self) { try await store.dbQueue.read { try authorize($0) } }
            pi.contextStore.apply(.local)
            let cancelled = Task { () throws in
                withUnsafeCurrentTask { $0?.cancel() }
                try await store.dbQueue.read { try authorize($0) }
            }
            await #expect(throws: (any Error).self) { try await cancelled.value }
        }

        @Test func scheduledRunsUseFreshSessionsAndSilentRunPreservesEarlierUnread() async throws {
            let transports = [TestPiTransport(), TestPiTransport()]
            let next = OSAllocatedUnfairLock(initialState: 0)
            let pi = TestPiRuntime { options in
                if options.mode == .chat {
                    let index = next.withLock { value in
                        defer { value += 1 }
                        return min(value, 1)
                    }
                    return transports[index]
                }
                return TestPiTransport(reply: TestPiRuntime.modelsReply([TestPiTransport.model(provider: "openai", id: "test")]))
            }
            let transport = transports[0]
            defer { try? FileManager.default.removeItem(at: pi.rootURL) }
            let store = try store()
            let schedules = AgentScheduleService(dbQueue: store.dbQueue)
            let now = Date()
            _ = try schedules.execute(
                .object(["action": .string("create"), "schedule": .string("30m"), "prompt": .string("Read only")]),
                account: "local",
                approved: true,
                tools: [],
                now: now
            )
            try schedules.tick(account: "local", now: now.addingTimeInterval(1801))
            let row = try #require(try schedules.list(account: "local").first)
            try await store.dbQueue.write { try $0.execute(sql: "UPDATE chat_schedules SET notify=0 WHERE id=?", arguments: [row.id]) }
            let chat = PiChatService(
                runtime: pi.service,
                historyStore: store,
                workingDirectory: PiWorkingDirectory(override: pi.rootURL.appending(path: "work")),
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: pi.rootURL),
                mcpExecutableURL: URL(filePath: "/usr/bin/true"),
                mcpSettings: { _ in AgentMCPSettings() },
                fileAccessSettings: { _ in .init() }
            )
            await chat.scheduleRuns(accountID: "local")
            let attached = try #require(try await chat.attach(threadID: row.threadID))
            await transport.emit(TestPiTransport.assistantEnd("First useful result"))
            await transport.emit(TestPiTransport.settled())
            for try await _ in attached.events {}
            #expect(try await chat.loadThread(id: row.threadID).isReadOnly)
            let launch = try #require(pi.launches.all.first { $0.mode == .chat })
            #expect(launch.profile == .scheduled && launch.arguments.contains("--no-session"))
            #expect(!launch.arguments.contains("--session") && !launch.arguments.contains("--session-id"))
            #expect(try schedules.unread(thread: row.threadID, account: "local"))
            _ = try schedules.execute(.object(["action": .string("run"), "job_id": .string(row.id)]), account: "local", approved: false, tools: [])
            await chat.scheduleRuns(accountID: "local")
            let second = try #require(try await chat.attach(threadID: row.threadID))
            #expect(second.snapshot?.isReadOnly == true)
            let prompt = await transports[1].command("prompt")
            #expect(prompt["message"]?.stringValue?.contains("First useful result") == true)
            await transports[1].emit(TestPiTransport.assistantEnd(String(repeating: "x", count: 9000) + "\n[SILENT]"))
            await transports[1].emit(TestPiTransport.settled())
            for try await _ in second.events {}
            #expect(pi.launches.all.filter { $0.mode == .chat }.count == 2)
            #expect(try schedules.unread(thread: row.threadID, account: "local"))
            let summary = try #require(store.listThreads(accountID: "local", cursor: nil).threads.first { $0.id == row.threadID })
            try await chat.markThreadSeen(id: row.threadID, through: #require(summary.lastItemSeq))
            #expect(try !schedules.unread(thread: row.threadID, account: "local"))
            let status = try await store.dbQueue.read {
                try String.fetchOne(
                    $0,
                    sql: "SELECT status FROM chat_schedule_fires WHERE runID=?",
                    arguments: [second.id]
                )
            }
            #expect(status == "silent")
            await chat.closeSession(row.threadID)
            await pi.service.shutdown()
        }
    }
#endif
