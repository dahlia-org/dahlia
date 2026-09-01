import GRDB
@testable import Dahlia

func insertLegacyVault(_ vault: VaultRecord, in db: Database) throws {
    try db.execute(
        sql: """
        INSERT INTO vaults (id, path, name, createdAt, lastOpenedAt)
        VALUES (?, ?, ?, ?, ?)
        """,
        arguments: [vault.id, vault.path, vault.name, vault.createdAt, vault.lastOpenedAt]
    )
}
