#if canImport(Testing)
    import Foundation
    import GRDB
    import Synchronization
    import Testing
    @testable import Dahlia

    @MainActor
    struct LocalAccountAISettingsTests {
        @Test
        func localInferenceUsesMacPreferencesForEitherAccountAndKeepsAccountOutputChoices() async throws {
            let suiteName = "MacInferenceSettingsTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let model = WorkspaceAISettingsModel(setupDefaults: defaults, activateRuntime: { _ in })
            model.localProvider = .databricks
            model.databricksProfile = "MAC"
            var server = makeWorkspace(openedAt: .now)
            server.accountConnectionId = .v7()
            server.organizationId = server.accountConnectionId == nil ? nil : (server.organizationId ?? .v7())
            server.summaryModelID = "not-the-mac-model"
            model.activate(workspace: server)
            #expect(await model.waitForRuntimeContext())
            server.generationSettings.summary.style = .concise
            server.generationSettings.outputLanguage = .fr
            let captured = SummaryGenerationSettings.current(workspaceAISettings: model, workspace: server)
            #expect(captured.modelID == "not-the-mac-model")
            #expect(captured.reasoningEffort == "high")
            #expect(captured.runtimeProvider == .databricks(profile: "MAC"))
            #expect(captured.languageDisplayName == SummaryLanguage.fr.displayName)
            #expect(captured.detailLevelInstruction == SummaryDetailLevel.concise.instruction)
            model.activate(workspace: makeWorkspace(openedAt: .now))
            #expect(await model.waitForRuntimeContext())
            #expect(SummaryGenerationSettings.current(workspaceAISettings: model, workspace: server).runtimeProvider == captured
                .runtimeProvider)
            #expect(captured.applying(detailLevel: .detailed).sourceAccountConnectionID == captured.sourceAccountConnectionID)
        }

        @Test
        func inheritsTheLatestLocalWorkspaceOnceAndKeepsExplicitChangesAfterRestart() async throws {
            let suiteName = "LocalAccountAISettingsTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(
                id: .v7(), origin: "https://server.example.com", clientID: "test", createdAt: .now
            )
            let older = makeWorkspace(openedAt: Date(timeIntervalSince1970: 1))
            var latest = makeWorkspace(openedAt: Date(timeIntervalSince1970: 2))
            latest.localProvider = .databricks
            latest.databricksProfile = "LOCAL"
            latest.summaryModelID = "latest-summary"
            latest.summaryReasoningEffort = "max"
            var server = makeWorkspace(openedAt: Date(timeIntervalSince1970: 3))
            server.accountConnectionId = connection.id
            server.organizationId = server.accountConnectionId == nil ? nil : (server.organizationId ?? .v7())
            server.databricksProfile = "SERVER"
            try await database.dbQueue.write { [latest, server] db in
                try connection.insert(db)
                try older.insert(db)
                try latest.insert(db)
                try server.insert(db)
            }
            let model = WorkspaceAISettingsModel(setupDefaults: defaults, activateRuntime: { _ in })

            model.configure(dbQueue: database.dbQueue)
            try await model.inheritLocalAccountSettings(from: database.dbQueue)

            #expect(model.localAccountSettings == .init(provider: .databricks, databricksProfile: "LOCAL"))
            #expect(defaults.string(forKey: LocalAccountAISettings.summaryModelKey) == nil)
            #expect(defaults.string(forKey: LocalAccountAISettings.summaryReasoningEffortKey) == nil)
            model.databricksProfile = "CHANGED"
            let restored = WorkspaceAISettingsModel(setupDefaults: defaults, activateRuntime: { _ in })
            restored.configure(dbQueue: database.dbQueue)
            try await restored.inheritLocalAccountSettings(from: database.dbQueue)
            #expect(restored.localAccountSettings == .init(provider: .databricks, databricksProfile: "CHANGED"))
            let storedProfile = try await database.dbQueue.read { [id = latest.id] db in
                try WorkspaceRecord.fetchOne(db, key: id)?.databricksProfile
            }
            #expect(storedProfile == "LOCAL")
        }

        @Test(arguments: [false, true])
        func retainsTheExistingAppSettingsWithoutBackfilledWorkspace(hasWorkspace: Bool) async throws {
            let suiteName = "LocalAccountAISettingsTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(AIAccountProvider.databricks.rawValue, forKey: LocalAccountAISettings.providerKey)
            defaults.set("LEGACY", forKey: LocalAccountAISettings.databricksProfileKey)
            let database = try AppDatabaseManager(path: ":memory:")
            if hasWorkspace {
                var pending = makeWorkspace(openedAt: .now)
                pending.aiSettingsBackfilled = false
                let workspace = pending
                try await database.dbQueue.write { db in try workspace.insert(db) }
            }
            let model = WorkspaceAISettingsModel(setupDefaults: defaults, activateRuntime: { _ in })

            model.configure(dbQueue: database.dbQueue)
            try await model.inheritLocalAccountSettings(from: database.dbQueue)

            #expect(model.localAccountSettings == .init(provider: .databricks, databricksProfile: "LEGACY"))
            #expect(defaults.bool(forKey: LocalAccountAISettings.migrationKey))
            #expect(!defaults.bool(forKey: LocalAccountAISettings.summaryMigrationKey))
        }

        @Test
        func providerChangesAreSharedAcrossWorkspacesWithoutActivatingTheHostedRuntime() async throws {
            let suiteName = "LocalAccountAISettingsTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let activations = Mutex<[WorkspaceAISettingsSnapshot]>([])
            let model = WorkspaceAISettingsModel(setupDefaults: defaults) { snapshot in
                activations.withLock { $0.append(snapshot) }
            }
            var server = makeWorkspace(openedAt: .now)
            server.accountConnectionId = .v7()
            server.organizationId = server.accountConnectionId == nil ? nil : (server.organizationId ?? .v7())
            server.summaryModelID = "hosted-summary"
            model.activate(workspace: server)
            #expect(await model.waitForRuntimeContext())

            model.localProvider = .databricks
            model.databricksProfile = "SHARED"
            #expect(activations.withLock { $0.count } == 1)
            #expect(model.accountConnectionID == server.accountConnectionId)
            #expect(model.summaryModelID == "hosted-summary")
            #expect(LocalAccountAISettings(defaults: defaults) == model.localAccountSettings)

            var local = makeWorkspace(openedAt: .now)
            local.summaryModelID = "local-summary"
            model.activate(workspace: local)
            #expect(await model.waitForRuntimeContext())
            #expect(model.summaryModelID == "local-summary")
            #expect(activations.withLock { $0.last?.localProvider } == .databricks)
            #expect(activations.withLock { $0.last?.databricksProfile } == "SHARED")
            model.databricksProfile = "NEW"
            #expect(await model.waitForRuntimeContext())
            #expect(activations.withLock { $0.last?.databricksProfile } == "NEW")

            model.activate(workspace: makeWorkspace(openedAt: .now))
            #expect(await model.waitForRuntimeContext())
            #expect(model.localAccountSettings == .init(provider: .databricks, databricksProfile: "NEW"))
        }

        @Test
        func successfulDatabricksActivationClearsTheMissingConnectionError() async throws {
            let suiteName = "LocalAccountAISettingsTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let model = WorkspaceAISettingsModel(setupDefaults: defaults) { snapshot in
                if snapshot.localProvider == .databricks, snapshot.databricksProfile.isEmpty {
                    throw CodexConfigurationError.databricksProfileRequired
                }
            }
            model.activate(workspace: makeWorkspace(openedAt: .now))
            #expect(await model.waitForRuntimeContext())

            model.localProvider = .databricks
            #expect(await !model.waitForRuntimeContext())
            #expect(model.errorMessage != nil)

            model.databricksProfile = "CONNECTED"
            #expect(await model.waitForRuntimeContext())
            #expect(model.errorMessage == nil)
        }

        @Test
        func runtimeRecoveryDoesNotClearAWorkspacePersistenceError() async throws {
            let suiteName = "LocalAccountAISettingsTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let database = try AppDatabaseManager(path: ":memory:")
            let workspace = makeWorkspace(openedAt: .now)
            try await database.dbQueue.write { db in
                try workspace.insert(db)
                try db.execute(sql: "CREATE TRIGGER fail_ai_settings_update BEFORE UPDATE ON workspaces BEGIN SELECT RAISE(ABORT, 'test persistence failure'); END")
            }
            let activations = Mutex(0)
            let model = WorkspaceAISettingsModel(setupDefaults: defaults) { _ in
                activations.withLock { $0 += 1 }
            }
            model.configure(dbQueue: database.dbQueue)
            model.activate(workspace: workspace)
            #expect(await model.waitForRuntimeContext())

            model.summaryModelID = "not-persisted"

            #expect(await pollUntil { activations.withLock { $0 == 2 } })
            #expect(await model.waitForRuntimeContext())
            #expect(model.errorMessage != nil)
        }

        @Test
        func failedBackfillDoesNotDisableSubsequentSettingsPersistence() async throws {
            let suiteName = "LocalAccountAISettingsTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            var workspace = makeWorkspace(openedAt: .now)
            workspace.aiSettingsBackfilled = false
            try repository.insertWorkspace(workspace)
            let model = WorkspaceAISettingsModel(setupDefaults: defaults, activateRuntime: { _ in })
            model.configure(dbQueue: database.dbQueue)
            try await database.dbQueue.write { db in
                try db.execute(sql: "CREATE TRIGGER fail_backfill BEFORE UPDATE ON workspaces BEGIN SELECT RAISE(ABORT, 'test failure'); END")
            }

            await #expect(throws: DatabaseError.self) {
                try await repository.backfillWorkspaceAISettings(.init(
                    chatModelID: "legacy", chatReasoningEffort: "high"
                ))
            }
            #expect(!defaults.bool(forKey: LocalAccountAISettings.migrationKey))
            try await database.dbQueue.write { db in
                try db.execute(sql: "DROP TRIGGER fail_backfill")
            }
            model.activate(workspace: workspace)
            model.summaryModelID = "updated"
            model.chatReasoningEffort = "low"

            let workspaceID = workspace.id
            #expect(await pollUntil {
                let stored = try? await database.dbQueue.read { db in
                    try WorkspaceRecord.fetchOne(db, key: workspaceID)
                }
                return stored?.summaryModelID == "updated" && stored?.chatReasoningEffort == "low"
            })
        }

        @Test
        func savingModelSettingsPreservesLegacyProviderColumns() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            var workspace = makeWorkspace(openedAt: .now)
            workspace.localProvider = .databricks
            workspace.databricksProfile = "OLD"
            try repository.insertWorkspace(workspace)
            var snapshot = WorkspaceAISettingsSnapshot(
                workspace: workspace,
                localAccountSettings: .init(provider: .chatGPTSubscription, databricksProfile: "")
            )
            snapshot.generationSettings.local.model = "new-model"

            let updated = try #require(try await repository.updateWorkspaceAISettings(snapshot))

            #expect(updated.localProvider == .databricks)
            #expect(updated.databricksProfile == "OLD")
            #expect(updated.summaryModelID == "new-model")
        }

        private func makeWorkspace(openedAt: Date) -> WorkspaceRecord {
            WorkspaceRecord(id: .v7(), path: nil, name: "Local", createdAt: .now, lastOpenedAt: openedAt)
        }
    }
#endif
