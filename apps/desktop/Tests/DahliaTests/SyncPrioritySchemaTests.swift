#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct SyncPrioritySchemaTests {
        @Test func reconciliationMigrationPreservesExistingWorkspace() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v50_syncPriority")
            let id = UUID.v7()
            try queue.write { db in
                try WorkspaceRecord(id: id, name: "Local", createdAt: .now, lastOpenedAt: .now).insert(db)
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db throws in
                #expect(try WorkspaceRecord.fetchOne(db, key: id)?.name == "Local")
                #expect(try db.tableExists("sync_reconciliations"))
                #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
            }
        }

        @Test
        func finalSchemaIncludesDurableSchedulingAndInitialConstruction() throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let tables = try database.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'sync_%' ORDER BY name"
                )
            }
            #expect(tables == [
                "sync_confirmed_relations",
                "sync_content_state",
                "sync_dependencies",
                "sync_dependency_keys",
                "sync_entity_state",
                "sync_initial_builds",
                "sync_initial_entities",
                "sync_operations",
                "sync_reconciliations",
                "sync_relation_history",
                "sync_scheduler_state",
                "sync_transactions",
                "sync_transcript_patch_items",
            ])

            let cloudWorkspaceExists = try database.dbQueue.read { db in
                try db.tableExists("cloud_workspaces")
            }
            #expect(!cloudWorkspaceExists)

            let transactionColumns = try database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('sync_transactions')")
            }
            #expect(!transactionColumns.contains("status"))
            #expect(!transactionColumns.contains("claimedAt"))

            let operationColumns = try database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('sync_operations')")
            }
            #expect(operationColumns.contains("attachmentReference"))
            #expect(!operationColumns.contains("expectedRevision"))

            let stateColumns = try database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('sync_entity_state')")
            }
            #expect(stateColumns == ["workspace_id", "entity", "entityId", "confirmedRevision"])
            let stateWorkspaceForeignKey = try database.dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT \"table\", \"from\", on_delete FROM pragma_foreign_key_list('sync_entity_state')"
                )
            }
            #expect(stateWorkspaceForeignKey?["table"] as String? == "workspaces")
            #expect(stateWorkspaceForeignKey?["from"] as String? == "workspace_id")
            #expect(stateWorkspaceForeignKey?["on_delete"] as String? == "CASCADE")
            let workspaceColumns = try database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('workspaces')")
            }
            #expect(!workspaceColumns.contains("syncEnabled"))
            let projectNameIndexes = try database.dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT count(*) FROM sqlite_master
                    WHERE type = 'index'
                      AND name IN ('projects_unique_root_name', 'projects_unique_child_name')
                    """
                ) ?? 0
            }
            #expect(projectNameIndexes == 0)
        }

    }
#endif
