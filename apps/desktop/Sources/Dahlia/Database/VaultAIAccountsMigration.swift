import GRDB

enum VaultAIAccountsMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists(VaultRecord.databaseTableName) else { return }
        try addColumnIfNeeded("accountConnectionId", type: .blob, in: db) { column in
            column.references(DahliaAccountConnectionRecord.databaseTableName, onDelete: .setNull)
        }
        try addColumnIfNeeded("localAIProvider", type: .text, in: db) { column in
            column.notNull().defaults(to: AIAccountProvider.chatGPTSubscription.rawValue)
        }
        try addColumnIfNeeded("databricksProfile", type: .text, in: db) { column in
            column.notNull().defaults(to: "")
        }
        try addColumnIfNeeded("summaryModelID", type: .text, in: db) { column in
            column.notNull().defaults(to: "gpt-5.6-luna")
        }
        try addColumnIfNeeded("summaryReasoningEffort", type: .text, in: db) { column in
            column.notNull().defaults(to: "high")
        }
        try addColumnIfNeeded("chatModelID", type: .text, in: db) { column in
            column.notNull().defaults(to: "")
        }
        try addColumnIfNeeded("chatReasoningEffort", type: .text, in: db) { column in
            column.notNull().defaults(to: CodexReasoningEffortOption.defaultValue)
        }
        try db.create(
            index: "vaults_on_accountConnectionId",
            on: VaultRecord.databaseTableName,
            columns: ["accountConnectionId"],
            ifNotExists: true
        )
    }

    private static func addColumnIfNeeded(
        _ name: String,
        type: Database.ColumnType,
        in db: Database,
        configure: (ColumnDefinition) -> Void
    ) throws {
        guard try !db.columns(in: VaultRecord.databaseTableName).contains(where: { $0.name == name }) else { return }
        try db.alter(table: VaultRecord.databaseTableName) { table in
            configure(table.add(column: name, type))
        }
    }
}

enum VaultAISettingsBackfillMigration {
    static func migrate(in db: Database) throws {
        guard try db.tableExists(VaultRecord.databaseTableName),
              try !db.columns(in: VaultRecord.databaseTableName).contains(where: { $0.name == "aiSettingsBackfilled" })
        else { return }
        try db.alter(table: VaultRecord.databaseTableName) { table in
            table.add(column: "aiSettingsBackfilled", .boolean).notNull().defaults(to: false)
        }
    }
}
