import Foundation
import Observation

/// The user's agents as the window shows them: the sidebar's rows, the card that makes or changes one, and the one
/// waiting for the user to confirm its deletion. The database and the homes are reached off MainActor through
/// `PiChatService`.
@MainActor
@Observable
final class AgentsModel {
    struct Draft: Equatable {
        /// nil while making a new agent.
        var id: String?
        var name = ""
        var avatar = AgentAvatar.random()
        var color = AgentAvatar.defaultColor
        /// The first `SOUL.md`; only a new agent takes it here, later it is edited in the side panel.
        var soul = ""
    }

    private(set) var summaries: [PiChatService.AgentSummary] = []
    private(set) var hasLoaded = false
    var draft: Draft?
    var pendingDeletion: AgentRecord?
    var error: String?
    private(set) var isBusy = false

    func refresh() async {
        guard let loaded = try? await PiChatService.shared.agentSummaries() else { return }
        summaries = loaded
        hasLoaded = true
    }

    /// The agent whose current thread this is, if any.
    func agent(currentThread threadID: String?) -> AgentRecord? {
        guard let threadID else { return nil }
        return summaries.first { $0.agent.threadID == threadID }?.agent
    }

    func newAgent(from template: AgentTemplate? = nil) {
        error = nil
        draft = template.map { Draft(name: $0.name, avatar: $0.avatar, color: $0.color, soul: $0.soul) } ?? Draft()
    }

    /// Fills the card being made with a template, replacing what the user typed.
    func apply(_ template: AgentTemplate) {
        guard draft?.id == nil else { return }
        draft = Draft(name: template.name, avatar: template.avatar, color: template.color, soul: template.soul)
    }

    func edit(_ agent: AgentRecord) {
        error = nil
        draft = Draft(id: agent.id, name: agent.name, avatar: agent.avatar, color: agent.color)
    }

    /// Saves the card; returns the new agent so the window can open it.
    func save() async -> AgentRecord? {
        guard let draft, !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            var created: AgentRecord?
            if let id = draft.id {
                try await PiChatService.shared.updateAgent(id, name: draft.name, avatar: draft.avatar, color: draft.color)
            } else {
                created = try await PiChatService.shared.createAgent(
                    name: draft.name, avatar: draft.avatar, color: draft.color, soul: draft.soul
                )
            }
            self.draft = nil
            error = nil
            await refresh()
            return created
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Saves a name or picture changed in place, in the agent's side panel.
    func update(_ agent: AgentRecord, name: String, avatar: String, color: String) async {
        do {
            try await PiChatService.shared.updateAgent(agent.id, name: name, avatar: avatar, color: color)
            error = nil
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    func delete(_ agent: AgentRecord) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        pendingDeletion = nil
        do {
            try await PiChatService.shared.deleteAgent(agent.id)
            error = nil
        } catch { self.error = error.localizedDescription }
        await refresh()
    }
}
