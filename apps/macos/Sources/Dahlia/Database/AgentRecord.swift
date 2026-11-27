import Foundation
import GRDB

/// One of the user's agents: who it is, where its home is, and its current thread. `agent.json` in its home is a copy
/// Dahlia writes from this row.
struct AgentRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    enum ModelUse: Sendable { case intake, unattended }

    static let databaseTableName = "agents"
    var id: String
    var name: String
    /// The home's folder name under `agents/`, fixed when the agent is made so a rename never moves its files.
    var directory: String
    /// `mascot:<id>`, one of the bundled pictures.
    var avatar: String
    /// The avatar's tile color, `#rrggbb`.
    var color: String
    /// The thread the user talks with it in; nil until it is first needed.
    var threadID: String?
    /// The model intake reads its event sources with; unset, Pi's default model.
    var intakeModel: String?
    var intakeEffort: String?
    /// The model of its turns that start without the user (event notices, results of its tasks); unset, its conversation's.
    var unattendedModel: String?
    var unattendedEffort: String?
    /// Whether it picks each launched thread's model and effort from the task (`PiChatService.smartRoutingPrompt`).
    var smartRouting = false
    var createdAt: Date
    var updatedAt: Date

    /// A chosen model and its effort, which the settings pick as one: with no model chosen, both follow the default.
    var intakeChoice: (model: String, effort: String?)? { intakeModel?.nilIfBlank.map { ($0, intakeEffort?.nilIfBlank) } }
    var unattendedChoice: (model: String, effort: String?)? {
        unattendedModel?.nilIfBlank.map { ($0, unattendedEffort?.nilIfBlank) }
    }
}
