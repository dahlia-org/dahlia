#if canImport(Testing)
    import DahliaRuntimeSupport
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct AgentIdentityModelTests {
        @Test(arguments: [false, true])
        func sidebarSavesClearRetainedFailureWithoutReplacingInlineDraft(editing: Bool) async throws {
            let runtime = TestPiRuntime { _ in TestPiTransport() }
            defer { try? FileManager.default.removeItem(at: runtime.rootURL) }
            let store = try await Task.detached {
                try ChatThreadStore(dbQueue: AppDatabaseManager(path: ":memory:").dbQueue)
            }.value
            let service = PiChatService(
                runtime: runtime.service, historyStore: store,
                agentLocator: PiAgentDirectoryLocator(applicationSupportURL: runtime.rootURL)
            )
            let original = try await service.createAgent(name: "Original", avatar: "mascot:E1", color: "#b3dbf4", soul: "")
            let other = try await service.createAgent(name: "Other", avatar: "mascot:E1", color: "#b3dbf4", soul: "")
            let owner = AgentsModel(service: service)
            let identity = owner.identity(for: original)
            identity.name = String(repeating: "x", count: 81)
            identity.save()
            try #require(await pollUntil { !identity.isSaving })
            let failure = try #require(identity.error)
            if editing { identity.name = "Unsaved inline draft" }

            owner.edit(other)
            owner.draft?.name = "Other renamed"
            _ = await owner.save()
            #expect(owner.draft == nil)
            #expect(identity.error == failure)

            owner.edit(original)
            owner.draft?.name = String(repeating: "x", count: 81)
            _ = await owner.save()
            #expect(owner.error != nil)
            #expect(identity.error == failure)

            // No Settings row or identity refresh observes the intermediate saved name.
            for name in ["Sidebar correction", original.name] {
                owner.edit(original)
                owner.draft?.name = name
                _ = await owner.save()
                #expect(owner.draft == nil)
                #expect(owner.error == nil)
                #expect(identity.error == nil)
                #expect(identity.name == (editing ? "Unsaved inline draft" : original.name))
            }
            let persisted = try await service.agent(original.id)
            identity.refresh(persisted, editingName: editing, pickingAvatar: false)
            #expect(identity.error == nil)
            #expect(identity.name == (editing ? "Unsaved inline draft" : original.name))
        }

        @Test
        func sidebarSuccessSupersedesAnOlderPendingInlineFailure() async throws {
            let original = agent()
            var completion: CheckedContinuation<Void, Never>?
            let identity = AgentIdentityModel(agent: original) { _, _, _ in
                await withCheckedContinuation { completion = $0 }
                return (original, "Older failure")
            }
            identity.name = String(repeating: "x", count: 81)
            identity.save()
            try #require(await pollUntil { completion != nil })
            identity.didSaveExternally()
            var corrected = original
            corrected.name = "Saved from sidebar"
            identity.refresh(corrected, editingName: false, pickingAvatar: false)
            completion?.resume()
            try #require(await pollUntil { !identity.isSaving })
            #expect(identity.error == nil)
            #expect(identity.name == corrected.name)
        }

        @Test
        func windowOwnerReusesEachAgentsIdentityAcrossNavigation() {
            let owner = AgentsModel()
            let original = agent()
            let first = owner.identity(for: original)
            let other = owner.identity(for: agent("Other"))
            #expect(owner.identity(for: original) === first)
            #expect(first !== other)
        }

        private func agent(_ name: String = "Original") -> AgentRecord {
            AgentRecord(
                id: UUID.v7().uuidString, name: name, directory: "original", avatar: "mascot:E1", color: "#b3dbf4",
                createdAt: .now, updatedAt: .now
            )
        }

        @Test
        func refreshKeepsFailureUntilTheSavedIdentityChanges() async throws {
            let original = agent()
            let model = AgentIdentityModel(agent: original) { _, _, _ in (original, "Save failed") }
            model.name = "Changed"
            model.save()
            try #require(await pollUntil { !model.isSaving })

            model.refresh(original, editingName: false, pickingAvatar: false)
            #expect(model.error == "Save failed")

            var corrected = original
            corrected.name = "Corrected in sidebar"
            model.refresh(corrected, editingName: false, pickingAvatar: false)
            #expect(model.error == nil)
            #expect(model.name == corrected.name)
        }

        @Test
        func rejectedRenameDoesNotBlockTheNextPictureSave() async throws {
            var saved = agent()
            var attemptedNames: [String] = []
            let model = AgentIdentityModel(agent: saved) { name, avatar, color in
                attemptedNames.append(name)
                do {
                    saved.name = try PiChatService.agentName(name)
                    saved.avatar = avatar
                    saved.color = color
                    return (saved, nil)
                } catch { return (saved, error.localizedDescription) }
            }
            let invalidName = String(repeating: "x", count: 81)
            model.name = invalidName
            model.save()
            try #require(await pollUntil { !model.isSaving })
            #expect(model.name == "Original")
            #expect(model.error != nil)

            let nextColor = try #require(AgentAvatar.colors.first { $0 != saved.color })
            model.color = nextColor
            model.save()
            try #require(await pollUntil { !model.isSaving })
            #expect(attemptedNames == [invalidName, "Original"])
            #expect(saved.color == nextColor)
            #expect(model.error == nil)
        }

        @Test
        func failureDoesNotMoveToAnotherAgent() async throws {
            let original = agent()
            let first = AgentIdentityModel(agent: original) { _, _, _ in (original, "Save failed") }
            first.name = "Changed"
            first.save()
            try #require(await pollUntil { !first.isSaving })
            let other = agent("Other")
            let second = AgentIdentityModel(agent: other) { _, _, _ in (other, nil) }
            #expect(first.error == "Save failed")
            #expect(second.error == nil)
            #expect(second.name == "Other")
        }
    }
#endif
