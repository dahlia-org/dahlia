#if canImport(Testing)
    import Foundation
    import GRDB
    import Testing
    @testable import Dahlia

    @MainActor
    struct WorkspaceGenerationSettingsTests {
        @Test(arguments: ["local", "admin", "editor", "viewer"])
        func sharedSettingsRequireAdministrationAndQueueAtomically(role: String) async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let connection = DahliaAccountConnectionRecord(id: .v7(), origin: "https://settings.invalid", clientID: "test", createdAt: .now)
            var workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Shared", createdAt: .now, lastOpenedAt: .now)
            if role != "local" {
                workspace.accountConnectionId = connection.id
                workspace.organizationId = .v7()
                workspace.syncRole = role
                workspace.syncConfirmedConnectionId = connection.id
                workspace.syncPullCursor = "confirmed"
            }
            let saved = workspace
            try await database.dbQueue.write { db in
                try connection.insert(db)
                try saved.insert(db)
            }
            let repository = MeetingRepository(dbQueue: database.dbQueue)
            var snapshot = WorkspaceAISettingsSnapshot(
                workspace: workspace,
                localAccountSettings: .init(provider: .chatGPTSubscription, databricksProfile: "")
            )
            snapshot.generationSettings.outputLanguage = .fr
            snapshot.generationSettings.local.model = "shared-model"
            snapshot.generationSettings.transcription.localeIdentifier = "fr-FR"
            snapshot.generationSettings.transcription.automaticLanguageDetection = true
            snapshot.generationSettings.transcription.languageScope = .selected
            // The settings checkbox uses this helper, which must retain the last candidate.
            snapshot.generationSettings.transcription.languageIdentifiers = AppLanguageSelection.updating(
                ["ja"], identifier: "ja", isEnabled: false
            ).sorted()
            #expect(snapshot.generationSettings.transcription.languageIdentifiers == ["ja"])
            snapshot.generationSettings.automaticProcessing = false
            if role == "local" || role == "admin" {
                let updated = try #require(try await repository.updateWorkspaceAISettings(snapshot))
                #expect(updated.generationSettings == snapshot.generationSettings)
                #expect(try await SyncTransactionQueue.hasPending(workspaceId: workspace.id, dbQueue: database.dbQueue) == (role == "admin"))
                let operation = try SyncInitialSnapshotBuilder.workspaceOperation(updated, action: .update)
                let payload = try JSONDecoder().decode(SyncCanonicalPayload.self, from: #require(operation.payloadJSON))
                #expect(payload.generationSettings == snapshot.generationSettings)
            } else {
                await #expect(throws: SyncTransactionQueueError.self) { try await repository.updateWorkspaceAISettings(snapshot) }
                let unchanged = try await database.dbQueue.read { db in try WorkspaceRecord.fetchOne(db, key: saved.id) }
                #expect(unchanged?.generationSettings == WorkspaceGenerationSettings())
                #expect(try await !SyncTransactionQueue.hasPending(workspaceId: saved.id, dbQueue: database.dbQueue))
            }
        }

        @Test
        func canonicalSettingsRefreshOpenWorkspaceWithoutEchoOrChangingAnotherWorkspace() async throws {
            let database = try AppDatabaseManager(path: ":memory:")
            let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Current", createdAt: .now, lastOpenedAt: .now)
            let other = WorkspaceRecord(id: .v7(), path: nil, name: "Other", createdAt: .now, lastOpenedAt: .now)
            try await database.dbQueue.write { db in
                try workspace.insert(db)
                try other.insert(db)
            }
            let suite = "WorkspaceGenerationSettingsTests-\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = WorkspaceAISettingsModel(setupDefaults: defaults, activateRuntime: { _ in })
            model.configure(dbQueue: database.dbQueue)
            model.activate(workspace: workspace)
            defer { model.clear() }
            var changed = WorkspaceGenerationSettings()
            changed.outputLanguage = .en
            changed.summary.style = .concise
            changed.local.model = "shared-model"
            changed.transcription.localeIdentifier = "en-US"
            changed.automaticProcessing = false
            let encoded = try String(decoding: JSONEncoder().encode(changed), as: UTF8.self)
            let payload = try SyncJSON.decoder.decode(
                SyncCanonicalPayload.self,
                from: Data("{\"name\":\"Current\",\"generationSettings\":\(encoded)}".utf8)
            )
            try await database.dbQueue.write { db in
                try SyncTransactionQueue.applyCanonical(.workspace, id: workspace.id, workspaceId: workspace.id, value: payload, in: db)
            }
            #expect(await pollUntil { model.generationSettings == changed })
            #expect(try await !SyncTransactionQueue.hasPending(workspaceId: workspace.id, dbQueue: database.dbQueue))
            #expect(model.snapshot(for: other.id).generationSettings == WorkspaceGenerationSettings())
            #expect(try await database.dbQueue.read { db in
                try WorkspaceRecord.fetchOne(db, key: other.id)?.generationSettings
            } == WorkspaceGenerationSettings())
        }
    }
#endif
