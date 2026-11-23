#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct AgentConnectionBindingTests {
        private func settings() throws -> AgentMCPSettings {
            let gateway = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://original.example.com")))
            return AgentMCPSettings(providers: [gateway], servers: [
                AgentMCPServer(id: .v7(), name: "gmail", providerID: gateway.id, service: "system.ai.gmail"),
            ])
        }

        @Test(arguments: ["registration", "endpoint"])
        func aTaskGrantNeverFollowsAReusedAlias(change: String) throws {
            let original = try settings()
            let id = try #require(original.connectionID(for: "gmail"))
            var task = AgentTaskRecord(
                id: UUID.v7().uuidString, accountID: "local", title: "Read", instructions: "Read", threadID: nil,
                status: "active", createdAt: .now, updatedAt: .now
            )
            task.servers = try String(decoding: JSONEncoder().encode([id]), as: UTF8.self)
            #expect(PiChatService.workerServerNames(task, settings: original) == ["gmail"])
            var replacement = original
            let gateway = try AgentMCPProvider(workspaceURL: #require(URL(string: "https://replacement.example.com")))
            replacement.providers = [gateway]
            replacement.servers = [AgentMCPServer(
                id: change == "registration" ? .v7() : original.servers[0].id,
                name: "gmail", providerID: gateway.id, service: "system.ai.gmail"
            )]
            #expect(replacement.connectionID(for: "gmail") != id)
            #expect(PiChatService.workerServerNames(task, settings: replacement).isEmpty)
            #expect(original.serverName(for: "gmail") == nil)
            replacement.servers = []
            #expect(PiChatService.workerServerNames(task, settings: replacement).isEmpty)
        }

        @Test(arguments: [false, true])
        func workRevocationPreservesOnlyIndependentSourceGrants(sourceAlsoGrants: Bool) throws {
            let settings = try settings()
            let id = try #require(settings.connectionID(for: "gmail"))
            var task = AgentTaskRecord(
                id: UUID.v7().uuidString, accountID: "local", title: "Read", instructions: "Read", threadID: nil,
                status: "active", createdAt: .now, updatedAt: .now
            )
            let grant = try String(decoding: JSONEncoder().encode([id]), as: UTF8.self)
            task.workServers = grant
            task.servers = sourceAlsoGrants ? grant : "[]"
            #expect(PiChatService.workerServerNames(task, settings: settings, allowedWorkConnections: [id]) == ["gmail"])
            #expect(PiChatService.workerServerNames(task, settings: settings).isEmpty == !sourceAlsoGrants)
        }

        @Test func acceptingAnOldSuggestionDoesNotRestoreRevokedWorkConsent() async throws {
            let settings = try settings()
            let id = try #require(settings.connectionID(for: "gmail"))
            let task = try await Task.detached {
                let service = try AgentInboxService(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
                let suggestion = try service.suggestTask(
                    title: "Read", instructions: "Read", eventIDs: [], servers: [id], caller: .router, account: "local"
                )
                #expect(try service.answer(itemID: suggestion.id, revision: 1, answer: "Yes", account: "local"))
                return try service.dbQueue.read { try #require(try AgentTaskRecord.fetchOne($0)) }
            }.value
            #expect(PiChatService.workerServerNames(task, settings: settings, allowedWorkConnections: [id]) == ["gmail"])
            #expect(PiChatService.workerServerNames(task, settings: settings).isEmpty)
        }

        @Test func workServerOptInBelongsToTheRegistration() throws {
            let suite = "AgentConnectionBindingTests.\(UUID.v7().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let provider = CodexRuntimeProvider.local
            let settings = try settings()
            let original = try #require(settings.connectionID(for: "gmail"))
            let model = AgentAlwaysOnSettingsModel(account: provider, defaults: defaults)
            model.connections = ["gmail": original]
            model.setWorkServer("gmail", allowed: true)
            #expect(model.isWorkServerAllowed("gmail"))
            #expect(AgentBotSettings.workServers(for: provider, defaults: defaults) == [original])
            model.connections = ["gmail": "replacement-registration"]
            #expect(!model.isWorkServerAllowed("gmail"))
            model.setWorkServer("gmail", allowed: true)
            #expect(model.isWorkServerAllowed("gmail"))
            model.setWorkServer("gmail", allowed: false)
            #expect(!model.isWorkServerAllowed("gmail"))
        }
    }
#endif
