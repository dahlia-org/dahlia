#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct SyncPrioritySchemaTests {
        @Test func reconciliationMigrationPreservesExistingWorkspace() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try DevelopmentSchemaHistory.migrator.migrate(queue, upTo: "v50_syncPriority")
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

        @Test(arguments: [
            "v47_orphanedRecordingRecoveryState",
            "v48_independentDocuments",
            "v49_workspaceImportDestinations",
            "v50_syncPriority",
            "v51_scopedSyncReconciliation",
        ])
        func consolidatedMigrationPreservesRowsAndMatchesFreshSchema(version: String) throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try DevelopmentSchemaHistory.migrator.migrate(queue, upTo: version)
            let workspace = UUID.v7(), meeting = UUID.v7(), document = UUID.v7()
            let hasDocuments = version != "v47_orphanedRecordingRecoveryState"
            try queue.write { db in
                try WorkspaceRecord(id: workspace, name: "Retained", createdAt: .now, lastOpenedAt: .now).insert(db)
                try MeetingRecord(id: meeting, workspaceId: workspace, name: "Meeting", createdAt: .now, updatedAt: .now).insert(db)
                try MeetingNoteRecord(meetingId: meeting, text: "private legacy\nNotes", createdAt: .now, updatedAt: .now).insert(db)
                if hasDocuments {
                    // Seed the historical schema without columns introduced by v54.
                    try db.execute(sql: """
                    INSERT INTO documents(id, workspace_id, meetingId, kind, checkpoint, text, createdAt, updatedAt)
                    VALUES (?, ?, ?, 'notes', 'AAA=', 'retained', ?, ?)
                    """, arguments: [document, workspace, meeting, Date.now, Date.now])
                    var update = DocumentUpdateRecord(documentId: document, payload: "AAA=", pending: true, createdAt: .now)
                    try update.insert(db)
                }
            }
            try AppDatabaseManager.migrator.migrate(queue)
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.read { db throws in
                #expect(try MeetingNoteRecord.fetchOne(db, key: meeting)?.text == "private legacy\nNotes")
                if hasDocuments {
                    #expect(try DocumentRecord.fetchOne(db, key: document)?.text == "retained")
                    #expect(try DocumentUpdateRecord.fetchOne(db)?.pending == true)
                }
                #expect(try AppDatabaseManager.hasExpectedCurrentSchema(db))
                #expect(try AppDatabaseManager.migrator.hasCompletedMigrations(db))
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                #expect(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations").contains("v47_orphanedRecordingRecoveryState"))
            }
        }

        @Test(arguments: ["v47_documents", "v51_scopedSyncReconciliation"], [false, true])
        func validatesHistoricalBackupWithoutTrustingUnexpectedTriggers(version: String, tampered: Bool) throws {
            let url = FileManager.default.temporaryDirectory.appending(path: "migration-backup-\(UUID.v7()).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }
            let queue = try DatabaseQueue(path: url.path, configuration: AppDatabaseManager.configuration())
            try DevelopmentSchemaHistory.migrator.migrate(queue, upTo: version)
            let workspace = UUID.v7()
            let entries = try String(decoding: JSONEncoder().encode([BackupWorkspace(id: workspace, name: "Retained")]), as: UTF8.self)
            try queue.write { db in
                try WorkspaceRecord(id: workspace, name: "Retained", createdAt: .now, lastOpenedAt: .now).insert(db)
                try db.execute(sql: """
                CREATE TABLE dahlia_backup_metadata (
                    formatVersion INTEGER, generationId TEXT, createdAt DATETIME, schemaVersion INTEGER,
                    migrationIdentifier TEXT, appVersion TEXT, appBuild TEXT, reason TEXT, workspacesJSON TEXT
                );
                INSERT INTO dahlia_backup_metadata VALUES (?, ?, ?, ?, ?, 'test', '1', 'manual', ?);
                """, arguments: [
                    BackupMetadata.currentFormatVersion,
                    UUID.v7().uuidString,
                    Date(),
                    AppDatabaseManager.schemaVersion(from: version),
                    version,
                    entries,
                ])
                if tampered {
                    try db.execute(sql: "CREATE TRIGGER unexpected AFTER UPDATE ON workspaces BEGIN DELETE FROM meetings; END")
                }
            }
            try queue.close()
            if tampered {
                #expect(throws: BackupServiceError.invalidBackup) { try BackupService.readAndValidateMetadata(at: url) }
            } else {
                #expect(try BackupService.readAndValidateMetadata(at: url).migrationIdentifier == version)
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
