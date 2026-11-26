import DahliaRuntimeSupport
import Foundation
import GRDB

/// Making, changing, and deleting the user's agents. Every view reaches them only through these.
extension PiChatService {
    static let agentNameLimit = 80

    nonisolated static func agentName(_ name: String) throws -> String {
        guard let name = name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank, name.count <= agentNameLimit else {
            throw AgentInboxService.Failure(message: L10n.agentNameInvalid)
        }
        return name
    }

    /// `soul` becomes the agent's first `SOUL.md`.
    func createAgent(name: String, avatar: String, color: String, soul: String, now: Date = .now) throws -> AgentRecord {
        let name = try Self.agentName(name)
        guard AgentAvatar.isValid(avatar: avatar, color: color) else { throw PiRuntimeError.invalidProtocolResponse }
        // A folder no row names (left by a database this Mac no longer has) is never adopted as a new agent's home.
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: agentLocator.agentsURL.path)) ?? []
        let agent = try history().dbQueue.write { db in
            let taken = try Set(String.fetchAll(db, sql: "SELECT directory FROM agents")).union(folders)
            let agent = AgentRecord(
                id: UUID.v7().uuidString, name: name, directory: AgentHome.directoryName(for: name, taken: taken),
                avatar: avatar, color: color, createdAt: now, updatedAt: now
            )
            try agent.insert(db)
            return agent
        }
        let home = try botHome(agent)
        if !soul.isEmpty { try AgentHome.saveSoul(soul, home: home) }
        return agent
    }

    /// A Pi process already running keeps the name it started with; the next one gets the new name.
    func updateAgent(_ id: String, name: String, avatar: String, color: String, now: Date = .now) throws {
        let name = try Self.agentName(name)
        guard AgentAvatar.isValid(avatar: avatar, color: color) else { throw PiRuntimeError.invalidProtocolResponse }
        let agent = try history().dbQueue.write { db in
            guard var agent = try AgentRecord.fetchOne(db, key: id) else { throw AgentInboxService.Failure(message: "Agent not found.") }
            agent.name = name
            agent.avatar = avatar
            agent.color = color
            agent.updatedAt = now
            try agent.update(db)
            if let threadID = agent.threadID {
                try db.execute(sql: "UPDATE chat_threads SET title=? WHERE id=?", arguments: [name, threadID])
            }
            return agent
        }
        _ = try botHome(agent)
        publishStates()
    }

    /// Empty follows the default: Pi's model for intake, the conversation's for unattended turns.
    func setAgentModels(
        _ id: String, intakeModel: String, intakeEffort: String, unattendedModel: String, unattendedEffort: String
    ) throws {
        try history().dbQueue.write { db in
            try db.execute(sql: """
            UPDATE agents SET intakeModel=?, intakeEffort=?, unattendedModel=?, unattendedEffort=? WHERE id=?
            """, arguments: [intakeModel.nilIfBlank, intakeEffort.nilIfBlank, unattendedModel.nilIfBlank, unattendedEffort.nilIfBlank, id])
        }
    }

    /// Deletes the agent with its sources, events, Tasks, and Items, and moves its home to the Trash. Its conversation
    /// stays in the history, read-only; the threads it launched stay as ordinary chats and keep running.
    func deleteAgent(_ id: String) async throws {
        let agent = try agent(id)
        try await history().dbQueue.write { db in
            if let threadID = agent.threadID {
                // The results of work it requested have nowhere to go; a result turn would be queued in a retired thread.
                try db.execute(
                    sql: "UPDATE chat_runs SET requestedByThreadID=NULL WHERE requestedByThreadID=? AND resultDeliveredAt IS NULL",
                    arguments: [threadID]
                )
            }
            _ = try AgentRecord.deleteOne(db, key: id)
        }
        botRetryAt[id] = nil
        if let threadID = agent.threadID {
            try history().interruptQueuedRuns(accountID: AppAccount.key, threadID: threadID)
            await retireBotThread(threadID)
        }
        // Closes an intake reading one of its sources, which are gone.
        await drainAlwaysOn()
        let home = agentLocator.agentHomeURL(agent.directory)
        if FileManager.default.fileExists(atPath: home.path) { try FileManager.default.trashItem(at: home, resultingItemURL: nil) }
        publishStates()
    }
}
