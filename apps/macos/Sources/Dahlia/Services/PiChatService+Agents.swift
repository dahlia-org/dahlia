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
    func createAgent(name: String, avatar: String, color: String, soul: String, now: Date = .now) async throws -> AgentRecord {
        let name = try Self.agentName(name)
        guard AgentAvatar.isValid(avatar: avatar, color: color) else { throw PiRuntimeError.invalidProtocolResponse }
        let store = try history()
        let agentsURL = agentLocator.agentsURL
        try PiAgentDirectoryLocator.createPrivateDirectory(agentsURL)
        // Inventory never substitutes for an exclusive claim, and a failed listing is not an empty directory.
        let folders = try FileManager.default.contentsOfDirectory(atPath: agentsURL.path)
        let taken = try await store.dbQueue.read { try Set(String.fetchAll($0, sql: "SELECT directory FROM agents")).union(folders) }
        let agent = AgentRecord(
            id: UUID.v7().uuidString, name: name, directory: AgentHome.directoryName(for: name, taken: taken),
            avatar: avatar, color: color, createdAt: now, updatedAt: now
        )
        let home = agentsURL.appending(path: agent.directory, directoryHint: .isDirectory)
        // Preparation owns its failure cleanup. No SQLite writer is held during filesystem work.
        try await initializeAgentHome(home, agent, soul)
        do {
            try await store.dbQueue.write { try agent.insert($0) }
            return agent
        } catch {
            try? FileManager.default.removeItem(at: home)
            throw error
        }
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
    func setAgentModel(_ id: String, use: AgentRecord.ModelUse, model: String, effort: String) throws {
        let (modelColumn, effortColumn) = switch use {
        case .intake: ("intakeModel", "intakeEffort")
        case .unattended: ("unattendedModel", "unattendedEffort")
        }
        try history().dbQueue.write { db in
            try db.execute(
                sql: "UPDATE agents SET \(modelColumn)=?, \(effortColumn)=? WHERE id=?",
                arguments: [model.nilIfBlank, effort.nilIfBlank, id]
            )
        }
    }

    /// Takes effect the next time the agent's Pi starts.
    func setAgentSmartRouting(_ id: String, _ enabled: Bool) throws {
        try history().dbQueue.write { try $0.execute(sql: "UPDATE agents SET smartRouting=? WHERE id=?", arguments: [enabled, id]) }
    }

    /// Deletes the agent with its sources, events, Tasks, and Items, and moves its home to the Trash. Its conversation
    /// stays in the history, read-only; the threads it launched stay as ordinary chats and keep running.
    func deleteAgent(_ id: String) async throws {
        let agent = try agent(id)
        try await history().dbQueue.write { db in
            if let threadID = agent.threadID {
                // Keep requester ancestry for recording and approval rules; only result delivery stops.
                try db.execute(
                    sql: "UPDATE chat_runs SET suppressAutomaticNotification=1 WHERE requestedByThreadID=?",
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
