import Foundation
import GRDB

/// The fixed import work survives queue acknowledgements, restart, and later edits.
struct LocalVaultImportRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "local_vault_imports"
    var id: UUID
    var sourceVaultId: UUID
    var destinationVaultId: UUID
    var connectionId: UUID
    var backupPath: String
    var createdAt: Date
    var completedAt: Date?

    static func acknowledge(transactionId: UUID, in db: Database) throws {
        try db.execute(sql: """
        UPDATE local_vault_import_operations SET completedAt = ?
        WHERE operationId IN (SELECT id FROM sync_operations WHERE transactionId = ?)
           OR replacementOperationId IN (SELECT id FROM sync_operations WHERE transactionId = ?)
        """, arguments: [Date.now, transactionId, transactionId])
        try complete(in: db)
    }

    static func complete(in db: Database) throws {
        try db.execute(sql: """
        UPDATE local_vault_imports SET completedAt = ? WHERE completedAt IS NULL
          AND NOT EXISTS (SELECT 1 FROM local_vault_import_operations o
              WHERE o.importId = local_vault_imports.id AND o.completedAt IS NULL)
        """, arguments: [Date.now])
    }
}
