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
            _ = try DahliaAccountConnectionRecord.deleteOne(db, key: id)
        }
    }
}
