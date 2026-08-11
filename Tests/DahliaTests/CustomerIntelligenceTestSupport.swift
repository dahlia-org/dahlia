import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    func customerIntelligenceVault(name: String) -> VaultRecord {
        VaultRecord(
            id: .v7(),
            path: "/tmp/\(name)-\(UUID.v7().uuidString)",
            name: name,
            createdAt: .now,
            lastOpenedAt: .now
        )
    }

    @MainActor
    final class CustomerIntelligenceFixture {
        let manager: AppDatabaseManager
        let repository: MeetingRepository
        let vault = customerIntelligenceVault(name: "Primary")
        let otherVault = customerIntelligenceVault(name: "Other")

        init() throws {
            manager = try AppDatabaseManager(path: ":memory:")
            repository = MeetingRepository(dbQueue: manager.dbQueue)
            try repository.insertVault(vault)
            try repository.insertVault(otherVault)
        }

        func insertMeeting() throws -> MeetingRecord {
            let meeting = MeetingRecord(
                id: .v7(),
                vaultId: vault.id,
                projectId: nil,
                name: "Customer sync",
                status: .ready,
                createdAt: .now,
                updatedAt: .now
            )
            try manager.dbQueue.write { db in
                try meeting.insert(db)
            }
            return meeting
        }
    }
#endif
