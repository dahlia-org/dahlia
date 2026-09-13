import GRDB
@testable import Dahlia

func insertLegacyWorkspace(_ workspace: WorkspaceRecord, in db: Database) throws {
    let table = try db.tableExists("workspaces") ? "workspaces" : "vaults"
    try db.execute(
        sql: """
        INSERT INTO \(table) (id, path, name, createdAt, lastOpenedAt)
        VALUES (?, ?, ?, ?, ?)
        """,
        arguments: [workspace.id, workspace.path, workspace.name, workspace.createdAt, workspace.lastOpenedAt]
    )
}
