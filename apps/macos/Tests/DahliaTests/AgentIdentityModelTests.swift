#if canImport(Testing)
    import Foundation
    import Testing
    @testable import Dahlia

    @MainActor
    struct AgentIdentityModelTests {
        private func agent(_ name: String = "Original") -> AgentRecord {
            AgentRecord(
                id: UUID.v7().uuidString, name: name, directory: "original", avatar: "mascot:E1", color: "#b3dbf4",
                createdAt: .now, updatedAt: .now
            )
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
