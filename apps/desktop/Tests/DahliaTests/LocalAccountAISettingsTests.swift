#if canImport(Testing)
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct LocalAccountAISettingsTests {
        @Test
        func inheritsTheLatestLocalVaultOnceAndKeepsExplicitChangesAfterRestart() async throws {
            let suiteName = "LocalAccountAISettingsTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "test", createdAt: .now
            )
            let older = makeVault(openedAt: Date(timeIntervalSince1970: 1))
            var latest = makeVault(openedAt: Date(timeIntervalSince1970: 2))
            latest.localProvider = .databricks
            latest.databricksProfile = "LOCAL"
            var server = makeVault(openedAt: Date(timeIntervalSince1970: 3))
            server.accountConnectionId = connection.id
            server.databricksProfile = "SERVER"
            try await database.dbQueue.write { [latest, server] db in
                try connection.insert(db)
                try older.insert(db)
                try latest.insert(db)
                try server.insert(db)
            }
            let model = VaultAISettingsModel(setupDefaults: defaults, activateRuntime: { _ in })

            try await model.configure(dbQueue: database.dbQueue)

            #expect(model.localAccountSettings == .init(provider: .databricks, databricksProfile: "LOCAL"))
            model.databricksProfile = "CHANGED"
            let restored = VaultAISettingsModel(setupDefaults: defaults, activateRuntime: { _ in })
            try await restored.configure(dbQueue: database.dbQueue)
            #expect(restored.localAccountSettings == .init(provider: .databricks, databricksProfile: "CHANGED"))
            let storedProfile = try await database.dbQueue.read { [id = latest.id] db in
                try VaultRecord.fetchOne(db, key: id)?.databricksProfile
            }
            #expect(storedProfile == "LOCAL")
        }

        @Test
        func retainsTheExistingAppSettingsWhenThereIsNoLocalVault() async throws {
            let suiteName = "LocalAccountAISettingsTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(AIAccountProvider.databricks.rawValue, forKey: LocalAccountAISettings.providerKey)
            defaults.set("LEGACY", forKey: LocalAccountAISettings.databricksProfileKey)
            let database = try AppDatabaseManager(path: ":memory:")
            let model = VaultAISettingsModel(setupDefaults: defaults, activateRuntime: { _ in })

            try await model.configure(dbQueue: database.dbQueue)

            #expect(model.localAccountSettings == .init(provider: .databricks, databricksProfile: "LEGACY"))
            #expect(defaults.bool(forKey: LocalAccountAISettings.migrationKey))
        }

        @Test
        func providerChangesAreSharedAcrossVaultsWithoutActivatingTheHostedRuntime() async throws {
            let suiteName = "LocalAccountAISettingsTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let activations = Mutex<[VaultAISettingsSnapshot]>([])
            let model = VaultAISettingsModel(setupDefaults: defaults) { snapshot in
                activations.withLock { $0.append(snapshot) }
            }
            var server = makeVault(openedAt: .now)
            server.accountConnectionId = .v7()
            server.summaryModelID = "hosted-summary"
            model.activate(vault: server)
            #expect(await model.waitForRuntimeContext())

            model.localProvider = .databricks
            model.databricksProfile = "SHARED"
            #expect(activations.withLock { $0.count } == 1)
            #expect(model.accountConnectionID == server.accountConnectionId)
            #expect(model.summaryModelID == "hosted-summary")
            #expect(LocalAccountAISettings(defaults: defaults) == model.localAccountSettings)

            var local = makeVault(openedAt: .now)
            local.summaryModelID = "local-summary"
            model.activate(vault: local)
            #expect(await model.waitForRuntimeContext())
            #expect(model.summaryModelID == "local-summary")
            #expect(activations.withLock { $0.last?.localProvider } == .databricks)
            #expect(activations.withLock { $0.last?.databricksProfile } == "SHARED")
            model.databricksProfile = "NEW"
            #expect(await model.waitForRuntimeContext())
            #expect(activations.withLock { $0.last?.databricksProfile } == "NEW")

            model.activate(vault: makeVault(openedAt: .now))
            #expect(await model.waitForRuntimeContext())
            #expect(model.localAccountSettings == .init(provider: .databricks, databricksProfile: "NEW"))
        }

        @Test
        func savingModelSettingsPreservesLegacyProviderColumns() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            var vault = makeVault(openedAt: .now)
            vault.localProvider = .databricks
            vault.databricksProfile = "OLD"
            try repository.insertVault(vault)
            var snapshot = VaultAISettingsSnapshot(
                vault: vault,
                localAccountSettings: .init(provider: .chatGPTSubscription, databricksProfile: "")
            )
            snapshot.summaryModelID = "new-model"

            let updated = try #require(try await repository.updateVaultAISettings(snapshot))

            #expect(updated.localProvider == .databricks)
            #expect(updated.databricksProfile == "OLD")
            #expect(updated.summaryModelID == "new-model")
        }

        private func makeVault(openedAt: Date) -> VaultRecord {
            VaultRecord(id: .v7(), path: nil, name: "Local", createdAt: .now, lastOpenedAt: openedAt)
        }
    }
#endif
