import Foundation
import GRDB

/// A new destination and its exact creation request survive a lost response or an interrupted import.
struct WorkspaceImportDestinationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "workspace_import_destinations"

    let sourceWorkspaceId: UUID
    let connectionId: UUID
    let organizationId: UUID
    let name: String
    let destinationWorkspaceId: UUID
    let requestJSON: Data

    static func prepare(
        sourceId: UUID, connection: DahliaAccountConnectionRecord, organizationId: UUID, name: String, in db: Database
    ) throws -> Self {
        guard let source = try WorkspaceRecord.fetchOne(db, key: sourceId), source.accountConnectionId == nil,
              let current = try DahliaAccountConnectionRecord.fetchOne(db, key: connection.id),
              current.origin == connection.origin, current.clientID == connection.clientID,
              try !RecordingSessionRecord.hasActiveRecording(workspaceId: sourceId, in: db),
              try !SyncTransactionQueue.hasPending(workspaceId: sourceId, in: db) else { throw LocalWorkspaceImportError.unavailable }
        if let existing = try Self.filter(Column("sourceWorkspaceId") == sourceId && Column("connectionId") == connection.id
            && Column("organizationId") == organizationId && Column("name") == name).fetchOne(db) { return existing }
        let destination = WorkspaceRecord(id: .v7(), path: nil, name: name, createdAt: .now, lastOpenedAt: .distantPast)
        let record = try Self(
            sourceWorkspaceId: sourceId,
            connectionId: connection.id,
            organizationId: organizationId,
            name: name,
            destinationWorkspaceId: destination.id,
            requestJSON: CloudWorkspaceDiscovery.creationRequest(destination, organizationId: organizationId)
        )
        try record.insert(db)
        return record
    }
}
