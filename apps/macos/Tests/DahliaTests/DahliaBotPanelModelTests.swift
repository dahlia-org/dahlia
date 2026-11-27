#if canImport(Testing)
    import Foundation
    import GRDB
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

        /// An Item an agent saves shows without waiting for the periodic refresh, and a new Task reloads the Task pages.
        @Test func observedInboxShowsSavedItemsAndTasksAtOnce() async throws {
            let (queue, inbox) = try await Task.detached {
                let queue = try AppDatabaseManager(path: ":memory:").dbQueue
                let agent = try queue.write { try AgentRecord.insertForTest(in: $0) }
                return (queue, AgentInboxService(dbQueue: queue, agentID: agent.id))
            }.value
            let model = DahliaBotPanelModel(loadTasks: { _, limit in try inbox.tasks(limit: limit) })
            model.agentID = inbox.agentID
            let agents = AgentsModel()
            let observing = Task { await model.observeInbox(in: queue) }
            let observingCounts = Task { await agents.observeOpenItems(in: queue) }
            defer {
                observing.cancel()
                observingCounts.cancel()
            }
            try #require(await pollUntil { agents.openItems[inbox.agentID] == 0 })

            let item = try await Task.detached { try inbox.createItem(kind: "report", title: "Saved") }.value
            #expect(await pollUntil { model.items.map(\.id) == [item.id] })
            #expect(await pollUntil { agents.openItems[inbox.agentID] == 1 })
            let task = try await Task.detached {
                let thread = UUID.v7().uuidString
                try ChatThreadStore(dbQueue: queue).createThread(ChatThreadRecord(
                    id: thread, accountID: AppAccount.key, title: "Task", createdAt: .now, updatedAt: .now
                ))
                return try inbox.openTask(threadID: thread, title: "Task", instructions: "", eventIDs: [])
            }.value
            #expect(await pollUntil { model.activeTasks.map(\.id) == [task.id] })
            _ = try await Task.detached { try inbox.dismiss(itemID: item.id, revision: item.revision) }.value
            #expect(await pollUntil { model.items.isEmpty })
            #expect(await pollUntil { agents.openItems[inbox.agentID] == 0 })
        }

        @Test func connectorSnapshotLoadsOffMainActorAndKeepsAccountProviderOrder() async throws {
            let account = try ProviderAccountDirectory.Connection(id: .v7(), workspaceURL: #require(URL(string: "https://account.example.com")))
            let remote = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://remote.example.com")))
            let accountProvider = AgentMCPProvider(workspaceURL: account.workspaceURL)
            let settings = AgentMCPSettings(providers: [remote, accountProvider], servers: [
                AgentMCPServer(id: .v7(), name: "slack", providerID: accountProvider.id, service: "system.ai.slack"),
            ])
            let service = PiChatService(mcpSettings: {
                #expect(!Thread.isMainThread)
                return settings
            })
            let snapshot = await ProviderAccountDirectory.$connections.withValue([account]) {
                await service.loadBotConnectors()
            }
            #expect(snapshot.providers.map(\.id) == [accountProvider.id, remote.id])
            let model = DahliaBotPanelModel(loadConnectorSettings: { snapshot })
            await model.refreshConnectors()
            #expect(model.servers == ["slack"])
            #expect(model.choiceName("slack") == "slack (account.example.com)")
        }

        @Test(arguments: [false, true])
        func connectorSnapshotsCannotPublishAfterSwitchingAgents(returnToOriginal: Bool) async throws {
            let loader = PendingConnectorSettings()
            let model = DahliaBotPanelModel(loadConnectorSettings: { await loader.load() })
            model.agentID = "A"
            let loading = Task { await model.refreshConnectors() }
            try #require(await pollUntil { await loader.isPending })
            model.agentID = "B"
            if returnToOriginal { model.agentID = "A" }
            let settings = AgentMCPSettings(servers: [
                AgentMCPServer(id: .v7(), name: "slack", providerID: nil, service: "slack", direct: .init(command: "slack-mcp")),
            ])
            await loader.release(settings)
            await loading.value
            #expect(model.servers.isEmpty && model.providers.isEmpty && model.connections.isEmpty)
        }

        @Test func switchingAgentsWaitsForSavedModelChoicesAndSavesOnlyTheEditedPair() async throws {
            let choices = ModelChoiceFixture()
            let model = DahliaBotPanelModel(
                loadAgent: { try await choices.load($0) },
                saveAgentModel: { try await choices.save($0, use: $1, model: $2, effort: $3) },
                saveSmartRouting: { try await choices.save($0, smartRouting: $1) }
            )
            model.agentID = "A"
            try await model.refreshModelSettings()
            #expect(model.areModelSettingsLoaded)
            model.agentID = "B"
            await choices.holdNextLoad()
            let loading = Task { try await model.refreshModelSettings() }
            try #require(await pollUntil { await choices.isPending })
            model.setIntakeModel("too early")
            model.setUnattendedModel("too early")
            model.setIntakeEffort("high")
            model.setUnattendedEffort("high")
            model.setSmartRouting(true)
            #expect(!model.areModelSettingsLoaded && model.intakeModel.isEmpty && model.unattendedModel.isEmpty)
            #expect(!model.smartRouting)
            #expect(await choices.writeCount == 0)
            await choices.release()
            try await loading.value
            #expect(model.areModelSettingsLoaded)
            #expect(model.intakeModel == "intake-B" && model.unattendedModel == "notice-B")
            model.setIntakeModel("edited")
            model.setUnattendedEffort("xhigh")
            try #require(await pollUntil { await choices.writeCount == 2 })
            let saved = try await choices.record("B")
            #expect(saved.intakeModel == "edited" && saved.intakeEffort == "low")
            #expect(saved.unattendedModel == "notice-B" && saved.unattendedEffort == "xhigh")
            #expect(try await choices.record("A").intakeModel == "intake-A")
            model.setSmartRouting(true)
            try #require(await pollUntil { await choices.writeCount == 3 })
            #expect(try await choices.record("B").smartRouting)
            #expect(try await !choices.record("A").smartRouting)

            await choices.holdNextLoad()
            let refreshing = Task { try await model.refreshModelSettings() }
            try #require(await pollUntil { await choices.isPending })
            model.setIntakeEffort("high")
            try #require(await pollUntil { await choices.writeCount == 4 })
            await choices.release()
            try await refreshing.value
            #expect(model.intakeEffort == "high")
        }

        @Test func modelRefreshCannotRevertAChoiceWhoseSaveIsPending() async throws {
            let choices = ModelChoiceFixture()
            let model = DahliaBotPanelModel(
                loadAgent: { try await choices.load($0) },
                saveAgentModel: { try await choices.save($0, use: $1, model: $2, effort: $3) }
            )
            model.agentID = "A"
            try await model.refreshModelSettings()
            await choices.holdNextSave()
            model.setIntakeModel("edited")
            try #require(await pollUntil { await choices.isSavePending })
            try await model.refreshModelSettings()
            #expect(model.intakeModel == "edited")
            await choices.releaseSave()
            try #require(await pollUntil { await choices.writeCount == 1 })
            #expect(try await choices.record("A").intakeModel == "edited")
        }

        @Test func failedModelSettingsLoadStaysDisabledAndCanRetry() async throws {
            let choices = ModelChoiceFixture()
            let model = DahliaBotPanelModel(loadAgent: { try await choices.load($0) })
            model.agentID = "B"
            await choices.holdNextLoad()
            let loading = Task { try await model.refreshModelSettings() }
            try #require(await pollUntil { await choices.isPending })
            await choices.release(fails: true)
            await #expect(throws: CancellationError.self) { try await loading.value }
            #expect(!model.areModelSettingsLoaded)
            try await model.refreshModelSettings()
            #expect(model.areModelSettingsLoaded && model.unattendedEffort == "medium")
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

        enum SelectionChange: CaseIterable {
            case anotherAgent, returnToOriginal, detachAndReturn
        }

        @Test(arguments: [false, true], SelectionChange.allCases)
        func soulSaveCannotPublishAfterSwitchingAgent(fails: Bool, change: SelectionChange) async throws {
            let writer = PendingSoulSave()
            let model = DahliaBotPanelModel(saveSoulFile: { _, _ in try await writer.save() })
            model.agentID = "A"
            model.soulDraft = "A saved guidance"
            let pending = Task { await model.saveSoul() }
            try #require(await pollUntil { await writer.isPending })
            model.agentID = change == .detachAndReturn ? nil : "B"
            if change != .anotherAgent { model.agentID = "A" }
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

    private actor ModelChoiceFixture {
        private var records: [String: AgentRecord] = Dictionary(uniqueKeysWithValues: ["A", "B"].map {
            ($0, AgentRecord(
                id: $0, name: $0, directory: $0, avatar: "mascot:E1", color: "#b3dbf4",
                intakeModel: "intake-" + $0, intakeEffort: "low", unattendedModel: "notice-" + $0,
                unattendedEffort: "medium", createdAt: .now, updatedAt: .now
            ))
        })
        private var holdSave = false
        private var pendingSave: CheckedContinuation<Void, Never>?
        var isSavePending: Bool { pendingSave != nil }
        func holdNextSave() { holdSave = true }
        func releaseSave() { pendingSave?.resume()
            pendingSave = nil
        }

        private var shouldHold = false
        private var pending: CheckedContinuation<AgentRecord, any Error>?
        private var snapshot: AgentRecord?
        private(set) var writeCount = 0
        var isPending: Bool { pending != nil }

        func record(_ id: String) throws -> AgentRecord { try #require(records[id]) }
        func holdNextLoad() { shouldHold = true }
        func load(_ id: String) async throws -> AgentRecord {
            let result = try record(id)
            guard shouldHold else { return result }
            shouldHold = false
            snapshot = result
            return try await withCheckedThrowingContinuation { pending = $0 }
        }

        func release(fails: Bool = false) {
            if fails { pending?.resume(throwing: CancellationError()) } else if let snapshot { pending?.resume(returning: snapshot) }
            pending = nil
            snapshot = nil
        }

        func save(_ id: String, use: AgentRecord.ModelUse, model: String, effort: String) async throws {
            if holdSave {
                holdSave = false
                await withCheckedContinuation { pendingSave = $0 }
            }
            var agent = try record(id)
            switch use {
            case .intake: (agent.intakeModel, agent.intakeEffort) = (model, effort)
            case .unattended: (agent.unattendedModel, agent.unattendedEffort) = (model, effort)
            }
            records[id] = agent
            writeCount += 1
        }

        func save(_ id: String, smartRouting: Bool) throws {
            var agent = try record(id)
            agent.smartRouting = smartRouting
            records[id] = agent
            writeCount += 1
        }
    }

    private actor PendingConnectorSettings {
        private var pending: CheckedContinuation<(settings: AgentMCPSettings, providers: [AgentMCPProvider]), Never>?
        var isPending: Bool { pending != nil }

        func load() async -> (settings: AgentMCPSettings, providers: [AgentMCPProvider]) {
            await withCheckedContinuation { pending = $0 }
        }

        func release(_ settings: AgentMCPSettings) {
            pending?.resume(returning: (settings, []))
            pending = nil
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
