#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct SchemaOrganizationTests {
        @Test
        func upgradePreservesRelationshipsAndClaimedSearchJobs() throws {
            let queue = try DatabaseQueue(configuration: AppDatabaseManager.configuration())
            try AppDatabaseManager.migrator.migrate(queue, upTo: "v41_vaultAISettingsBackfill")
            let vaultId = UUID.v7()
            let projectId = UUID.v7()
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO vaults(id, path, name, createdAt, lastOpenedAt) VALUES (?, '/tmp/schema', 'Vault', ?, ?)",
                    arguments: [vaultId, Date.now, Date.now]
                )
                try db.execute(sql: """
                INSERT INTO projects(id, vaultId, name, nameKey, createdAt, projectType, revision)
                VALUES (?, ?, 'Project', 'project', ?, 'undefined', 9)
                """, arguments: [projectId, vaultId, Date.now])
                try db.execute(sql: """
                UPDATE search_index_jobs SET generation = 7, status = 'processing', attempts = 3, claimedAt = ?, leaseExpiresAt = ?
                WHERE targetKey = ?
                """, arguments: [Date.now, Date.now.addingTimeInterval(60), projectId])
            }
            let before = try queue.read { try Row.fetchAll($0, sql: "SELECT * FROM search_index_jobs ORDER BY targetKey") }
            #expect(!before.isEmpty)
            try AppDatabaseManager.migrator.migrate(queue)
            try queue.write { db in
                try SchemaOrganizationMigration.migrate(in: db)
                #expect(try Row.fetchAll(db, sql: "SELECT * FROM jobs_search_index ORDER BY targetKey") == before)
                #expect(try !db.tableExists("search_index_jobs"))
                let project = try #require(try ProjectRecord.fetchOne(db, key: projectId))
                #expect(project.vaultId == vaultId && project.revision == 9)
                #expect(project.icon == nil && project.color == nil)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                try db.execute(sql: "UPDATE projects SET name = 'Changed', nameKey = 'changed' WHERE id = ?", arguments: [projectId])
                #expect(try String.fetchOne(
                    db,
                    sql: "SELECT status FROM jobs_search_index WHERE targetKind = 'projectHierarchy' AND targetKey = ?",
                    arguments: [projectId]
                ) == "pending")
            }
        }

        @Test
        func migratesLegacyDefaultsOnceAndPreservesCanonicalAppearance() async throws {
            let (database, vault, project) = try fixture()
            let suite = "SchemaOrganizationTests-\(UUID.v7())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let appearance = ProjectAppearance(icon: .music, color: .purple)
            try defaults.set(JSONEncoder().encode([vault.id.uuidString: [project.id.uuidString: appearance]]), forKey: "projectAppearances")
            let navigation = MainWindowNavigation(openMainWindow: {}, settingsDefaults: defaults)
            try await navigation.migrateProjectAppearances(vaultId: vault.id, dbQueue: database.dbQueue)
            let migrated = try await database.dbQueue.read { try #require(try ProjectRecord.fetchOne($0, key: project.id)) }
            #expect(migrated.icon == "music.note" && migrated.color == "purple")
            #expect(migrated.revision == project.revision + 1)
            try await navigation.migrateProjectAppearances(vaultId: vault.id, dbQueue: database.dbQueue)
            #expect(try await database.dbQueue.read { try ProjectRecord.fetchOne($0, key: project.id)?.revision } == migrated.revision)
            let saved = try JSONDecoder().decode(
                [String: [String: ProjectAppearance]].self,
                from: #require(defaults.data(forKey: "projectAppearances"))
            )
            #expect(saved[vault.id.uuidString]?[project.id.uuidString] == nil)
            let completed = try await ProjectAppearanceMigration.migrate(
                [project.id.uuidString: ProjectAppearance(icon: .folder, color: .red)], vaultId: vault.id, dbQueue: database.dbQueue
            )
            #expect(completed == [project.id.uuidString])
            #expect(try await database.dbQueue.read { try ProjectRecord.fetchOne($0, key: project.id)?.color } == "purple")
        }

        @Test
        func remoteMigrationWaitsForConfirmationAndRetainsDefaultsUntilAcknowledged() async throws {
            let (database, vault, project) = try fixture(remote: true)
            let saved = [project.id.uuidString: ProjectAppearance(icon: .music, color: .purple)]
            #expect(try await ProjectAppearanceMigration.migrate(saved, vaultId: vault.id, dbQueue: database.dbQueue).isEmpty)
            #expect(try await database.dbQueue.read { try ProjectRecord.fetchOne($0, key: project.id)?.icon } == nil)
            try await database.dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_entity_state(vaultId, entity, entityId, confirmedRevision) VALUES (?, 'project', ?, 4)",
                    arguments: [vault.id, project.id]
                )
            }
            #expect(try await ProjectAppearanceMigration.migrate(saved, vaultId: vault.id, dbQueue: database.dbQueue).isEmpty)
            let transaction = try await database.dbQueue.read { db in
                let row = try #require(try Row.fetchOne(
                    db,
                    sql: "SELECT transactionId, payloadJSON, baseRevision FROM sync_operations WHERE entity = 'project'"
                ))
                return (id: row["transactionId"] as UUID, payload: row["payloadJSON"] as String, revision: row["baseRevision"] as Int)
            }
            #expect(transaction.revision == 4)
            let payload = try #require(transaction.payload.data(using: .utf8))
            let json = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
            #expect(json["icon"] as? String == "music.note")
            #expect(try await ProjectAppearanceMigration.migrate(saved, vaultId: vault.id, dbQueue: database.dbQueue).isEmpty)
            #expect(try await database.dbQueue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_operations") } == 1)
            // Model the durable acknowledgement: the real receipt path is covered by sync round-trip tests.
            let transactionId = transaction.id
            try await database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM sync_transactions WHERE id = ?", arguments: [transactionId])
                try db.execute(sql: "UPDATE sync_entity_state SET confirmedRevision = 5 WHERE entityId = ?", arguments: [project.id])
                // A user accepting an unset canonical value must not re-import the old preference.
                try db.execute(sql: "UPDATE projects SET icon = NULL, color = NULL WHERE id = ?", arguments: [project.id])
            }
            #expect(try await ProjectAppearanceMigration.migrate(saved, vaultId: vault.id, dbQueue: database.dbQueue) == [project.id.uuidString])
            #expect(try await database.dbQueue.read { try ProjectRecord.fetchOne($0, key: project.id)?.icon } == nil)
        }

        @Test
        func sharedMemberCannotMigrateLegacyAppearance() async throws {
            let (database, vault, project) = try fixture(remote: true)
            try await database.dbQueue.write { db in
                try db.execute(sql: "UPDATE vaults SET syncRole = 'member' WHERE id = ?", arguments: [vault.id])
            }
            let completed = try await ProjectAppearanceMigration.migrate(
                [project.id.uuidString: ProjectAppearance(icon: .music, color: .purple)], vaultId: vault.id, dbQueue: database.dbQueue
            )
            #expect(completed.isEmpty)
            #expect(try await database.dbQueue.read { try ProjectRecord.fetchOne($0, key: project.id)?.icon } == nil)
        }

        @Test
        func canonicalAppearanceRoundTripsThroughSnapshotAndClearsWithNull() throws {
            let (database, vault, project) = try fixture()
            try database.dbQueue.write { db in
                for entity in [SyncEntity.vault, .project] {
                    let id = entity == .vault ? vault.id : project.id
                    for fields in [#""icon":"music.note","color":"blue""#, #""icon":null,"color":null"#] {
                        let data = Data("{\(fields),\"name\":\"Project\",\"projectType\":\"undefined\",\"createdAt\":\"2026-09-03T00:00:00Z\"}".utf8)
                        let value = try SyncJSON.decoder.decode(SyncCanonicalPayload.self, from: data)
                        try SyncTransactionQueue.applyCanonical(entity, id: id, vaultId: vault.id, value: value, in: db)
                        let operation: SyncOperationDraft
                        if entity == .vault {
                            let saved = try #require(try VaultRecord.fetchOne(db, key: id))
                            #expect(saved.icon == value.icon && saved.color == value.color)
                            operation = try SyncInitialSnapshotBuilder.vaultOperation(saved, action: .create)
                        } else {
                            let saved = try #require(try ProjectRecord.fetchOne(db, key: id))
                            #expect(saved.icon == value.icon && saved.color == value.color)
                            operation = try SyncInitialSnapshotBuilder.projectOperation(saved, action: .create)
                        }
                        let payload = try #require(operation.payloadJSON)
                        let json = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
                        if value.icon == nil {
                            #expect(json["icon"] is NSNull && json["color"] is NSNull)
                        } else {
                            #expect(json["icon"] as? String == value.icon && json["color"] as? String == value.color)
                        }
                    }
                }
            }
        }

        private func fixture(remote: Bool = false) throws -> (AppDatabaseManager, VaultRecord, ProjectRecord) {
            let database = try AppDatabaseManager(path: ":memory:")
            var vault = VaultRecord(id: .v7(), name: "Vault", createdAt: .now, lastOpenedAt: .now)
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://server.example", clientID: "desktop", createdAt: .now)
            if remote {
                vault.accountConnectionId = connection.id
                vault.syncConfirmedConnectionId = connection.id
                vault.syncRole = "owner"
            }
            let savedVault = vault
            let project = ProjectRecord(id: .v7(), vaultId: vault.id, parentProjectId: nil, name: "Project", createdAt: .now, projectType: .undefined)
            try database.dbQueue.write { db in
                if remote { try connection.insert(db) }
                try savedVault.insert(db)
                try project.insert(db)
            }
            return (database, vault, project)
        }
    }
#endif
