import Foundation
import GRDB

extension MeetingRepository {
    nonisolated func fetchDahliaAccountConnections() async throws -> [DahliaAccountConnectionRecord] {
        try await dbQueue.read { db in
            try DahliaAccountConnectionRecord.dahliaServers
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    nonisolated func fetchDahliaAccountConnection(id: UUID) async throws -> DahliaAccountConnectionRecord? {
        try await dbQueue.read { db in
            try DahliaAccountConnectionRecord.fetchOne(db, key: id)
        }
    }

    nonisolated func insertDahliaAccountConnection(_ connection: DahliaAccountConnectionRecord) async throws {
        try await dbQueue.write { db in
            try connection.insert(db)
        }
    }

    nonisolated func deleteDahliaAccountConnection(id: UUID) async throws {
        try await dbQueue.write { db in
            _ = try DahliaAccountConnectionRecord.deleteOne(db, key: id)
            // Deleting the account removes its chats with its agent directory; sign-out keeps both.
            try db.execute(sql: "DELETE FROM chat_threads WHERE accountID = ?", arguments: [id.uuidString.lowercased()])
            try db.execute(sql: "DELETE FROM agent_system_runs WHERE accountID = ?", arguments: [id.uuidString.lowercased()])
            for table in [
                "agent_user_inbox",
                "agent_worker_deliveries",
                "agent_event_inbox",
                "agent_timers",
                "agent_action_outbox",
                "agent_event_topics",
                "agent_tasks",
                "agent_event_sources",
                "agent_action_policies",
                "agent_always_on_settings",
            ] {
                try db.execute(sql: "DELETE FROM \(table) WHERE accountID = ?", arguments: [id.uuidString.lowercased()])
            }
        }
        AgentBotSettings.remove(accountKey: id.uuidString.lowercased())
    }

}
