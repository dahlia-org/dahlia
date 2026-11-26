#if canImport(Testing)
    import Foundation
    import GRDB
    @testable import Dahlia

    extension AgentRecord {
        /// An agent row for a test database; its home folder is not made.
        @discardableResult
        static func insertForTest(name: String = "Agent", in db: Database) throws -> AgentRecord {
            let agent = AgentRecord(
                id: UUID.v7().uuidString, name: name, directory: UUID.v7().uuidString.lowercased(),
                avatar: AgentAvatar.mascot("E1"), color: AgentAvatar.defaultColor, createdAt: .now, updatedAt: .now
            )
            try agent.insert(db)
            return agent
        }
    }
#endif
