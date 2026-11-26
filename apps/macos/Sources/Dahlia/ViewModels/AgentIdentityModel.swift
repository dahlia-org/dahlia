import Foundation
import Observation

/// A single agent's inline identity draft and the result of saving it.
@MainActor
@Observable
final class AgentIdentityModel {
    private(set) var agent: AgentRecord
    var name: String
    var avatar: String
    var color: String
    private(set) var isSaving = false
    private(set) var error: String?
    private let onSave: (String, String, String) async -> (agent: AgentRecord, error: String?)

    init(agent: AgentRecord, onSave: @escaping (String, String, String) async -> (agent: AgentRecord, error: String?)) {
        self.agent = agent
        name = agent.name
        avatar = agent.avatar
        color = agent.color
        self.onSave = onSave
    }

    func refresh(_ agent: AgentRecord, editingName: Bool, pickingAvatar: Bool) {
        if agent.name != self.agent.name || agent.avatar != self.agent.avatar || agent.color != self.agent.color {
            error = nil
        }
        self.agent = agent
        if !editingName { name = agent.name }
        if !pickingAvatar {
            avatar = agent.avatar
            color = agent.color
        }
    }

    func save() {
        guard !isSaving else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            name = agent.name
            return
        }
        guard trimmed != agent.name || avatar != agent.avatar || color != agent.color else { return }
        isSaving = true
        Task { [avatar, color] in
            let result = await onSave(trimmed, avatar, color)
            agent = result.agent
            name = result.agent.name
            self.avatar = result.agent.avatar
            self.color = result.agent.color
            error = result.error
            isSaving = false
        }
    }
}
