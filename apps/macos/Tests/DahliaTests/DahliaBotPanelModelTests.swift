#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct DahliaBotPanelModelTests {
        private func task(_ id: String) -> AgentTaskRecord {
            AgentTaskRecord(id: id, agentID: "agent", title: id, instructions: "", threadID: nil, status: "done", createdAt: .now, updatedAt: .now)
        }

        private func model(_ loader: TaskPageLoader) throws -> DahliaBotPanelModel {
            let model = DahliaBotPanelModel(loadTasks: { _, limit in try await loader.load(limit: limit) })
            model.agentID = "agent"
            return model
        }

        @Test func overlappingMoreRequestsExpandTheRangeOnce() async throws {
            let first = task("first"), next = task("next")
            let loader = TaskPageLoader(following: [first, next])
            let model = try model(loader)
            model.finishedTasks = [first]
            let pending = Task { await model.loadMoreFinishedTasks() }
            try #require(await pollUntil { await loader.requestCount == 1 })
            await model.loadMoreFinishedTasks()
            #expect(await loader.requestCount == 1)
            await loader.releaseFirst([first, next])
            await pending.value
            #expect(model.finishedTasks.map(\.id) == [first.id, next.id])
            #expect(!model.isLoadingFinishedTasks)
        }

        @Test func anOlderRefreshCannotEraseAPageTheUserJustLoaded() async throws {
            let first = task("first"), next = task("next")
            let loader = TaskPageLoader(following: [first, next])
            let model = try model(loader)
            model.finishedTasks = [first]
            let refresh = Task { try await model.refreshTasks() }
            try #require(await pollUntil { await loader.requestCount == 1 })
            await model.loadMoreFinishedTasks()
            await loader.releaseFirst([first])
            try await refresh.value
            #expect(model.finishedTasks.map(\.id) == [first.id, next.id])
        }

        @Test func newerRefreshPreservesTheRequestedPageDepth() async throws {
            let first = task("first"), next = task("next")
            let loader = TaskPageLoader(following: [first, next])
            let model = try model(loader)
            model.finishedTasks = [first]
            let pending = Task { await model.loadMoreFinishedTasks() }
            try #require(await pollUntil { await loader.requestCount == 1 })
            try await model.refreshTasks()
            #expect(await loader.limits == [60, 60])
            await loader.releaseFirst([first])
            await pending.value
            #expect(model.finishedTasks.map(\.id) == [first.id, next.id])
        }

        @Test func aSavedTaskChangeRefreshesDuringAPendingPage() async throws {
            let first = task("first"), completed = task("completed")
            let loader = TaskPageLoader(following: [completed, first])
            let model = try model(loader)
            var active = completed
            active.status = "active"
            model.activeTasks = [active]
            model.finishedTasks = [first]
            let pending = Task { await model.loadMoreFinishedTasks() }
            try #require(await pollUntil { await loader.requestCount == 1 })
            try await model.refreshTasks()
            #expect(await loader.requestCount == 2)
            #expect(model.activeTasks.isEmpty)
            #expect(model.finishedTasks.map(\.id) == [completed.id, first.id])
            await loader.releaseFirst([first])
            await pending.value
            #expect(model.activeTasks.isEmpty)
            #expect(model.finishedTasks.map(\.id) == [completed.id, first.id])
        }

        @Test func failedPageReleasesLoadingAndCanRetry() async throws {
            let first = task("first"), next = task("next")
            let loader = TaskPageLoader(following: [first, next])
            let model = try model(loader)
            model.finishedTasks = [first]
            let pending = Task { await model.loadMoreFinishedTasks() }
            try #require(await pollUntil { await loader.requestCount == 1 })
            await loader.failFirst()
            await pending.value
            #expect(!model.isLoadingFinishedTasks && model.error != nil)
            await model.loadMoreFinishedTasks()
            #expect(model.finishedTasks.map(\.id) == [first.id, next.id])
            #expect(await loader.limits == [60, 60])
        }

        @Test func anOlderRefreshCannotReplaceANewerTaskSnapshot() async throws {
            let old = task("old"), new = task("new")
            let loader = TaskPageLoader(following: [new])
            let model = try model(loader)
            let older = Task { try await model.refreshTasks() }
            try #require(await pollUntil { await loader.requestCount == 1 })
            try await model.refreshTasks()
            await loader.releaseFirst([old])
            try await older.value
            #expect(model.finishedTasks.map(\.id) == [new.id])
        }

        @Test(arguments: [false, true], [false, true])
        func soulSaveCannotPublishAfterSwitchingAgent(fails: Bool, returnsToOriginal: Bool) async throws {
            let writer = PendingSoulSave()
            let model = DahliaBotPanelModel(saveSoulFile: { _, _ in try await writer.save() })
            model.agentID = "A"
            model.soulDraft = "A saved guidance"
            let pending = Task { await model.saveSoul() }
            try #require(await pollUntil { await writer.isPending })
            model.agentID = "B"
            if returnsToOriginal { model.agentID = "A" }
            model.soul = "Current guidance"
            model.soulDraft = "Current unsaved draft"
            await writer.complete(fails: fails)
            await pending.value
            #expect(model.soul == "Current guidance")
            #expect(model.soulDraft == "Current unsaved draft")
            #expect(model.error == nil)
        }

        @Test func oldPageFailureCannotRollBackAnotherAgentsPageDepth() async throws {
            let first = task("first"), next = task("next")
            let loader = TaskPageLoader(following: [first, next])
            let model = try model(loader)
            model.finishedTasks = [first]
            let pending = Task { await model.loadMoreFinishedTasks() }
            try #require(await pollUntil { await loader.requestCount == 1 })
            model.agentID = "B"
            #expect(!model.isLoadingFinishedTasks)
            model.finishedTasks = [first]
            await model.loadMoreFinishedTasks()
            await loader.failFirst()
            await pending.value
            try await model.refreshTasks()
            #expect(await loader.limits == [60, 60, 60])
            #expect(model.error == nil)
            #expect(model.finishedTasks.map(\.id) == [first.id, next.id])
        }
    }

    private actor PendingSoulSave {
        private var continuation: CheckedContinuation<Void, any Error>?
        var isPending: Bool { continuation != nil }

        func save() async throws {
            try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func complete(fails: Bool) {
            if fails { continuation?.resume(throwing: CancellationError()) } else { continuation?.resume() }
            continuation = nil
        }
    }

    private actor TaskPageLoader {
        typealias Page = (active: [AgentTaskRecord], finished: [AgentTaskRecord])
        private let following: [AgentTaskRecord]
        private var first: CheckedContinuation<Page, any Error>?
        private(set) var requestCount = 0
        private(set) var limits: [Int] = []

        init(following: [AgentTaskRecord]) { self.following = following }

        func load(limit: Int) async throws -> Page {
            requestCount += 1
            limits.append(limit)
            if requestCount == 1 {
                return try await withCheckedThrowingContinuation { first = $0 }
            }
            return ([], following)
        }

        func failFirst() {
            first?.resume(throwing: CancellationError())
            first = nil
        }

        func releaseFirst(_ tasks: [AgentTaskRecord]) {
            first?.resume(returning: ([], tasks))
            first = nil
        }
    }
#endif
