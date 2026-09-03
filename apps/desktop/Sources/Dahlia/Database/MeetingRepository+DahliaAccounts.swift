import Foundation
import GRDB

extension MeetingRepository {
    nonisolated func fetchDahliaAccountConnections() async throws -> [DahliaAccountConnectionRecord] {
        try await dbQueue.read { db in
            try DahliaAccountConnectionRecord
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
            guard try !Self.connectionHasPendingServerDeletion(id: id, in: db) else {
                throw DahliaAccountConnectionError.pendingServerDeletion
            }
            _ = try DahliaAccountConnectionRecord.deleteOne(db, key: id)
        }
    }

    nonisolated func connectionHasPendingServerDeletion(id: UUID) async throws -> Bool {
        try await dbQueue.read { db in
            try Self.connectionHasPendingServerDeletion(id: id, in: db)
        }
    }

    private nonisolated static func connectionHasPendingServerDeletion(id: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS (SELECT 1 FROM vaults WHERE syncDeletionConnectionId = ? OR syncConfirmedConnectionId = ?)",
            arguments: [id, id]
        ) ?? false
    }
}

enum DahliaAccountConnectionError: LocalizedError {
    case pendingServerDeletion

    var errorDescription: String? {
        L10n.dahliaAccountPendingServerDeletion
    }
}
