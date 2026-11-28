import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    @MainActor
    struct BackupSettingsViewModelTests {
        @Test(arguments: [false, true])
        func creationOwnsTheLocalSlotAndWorkspaceSelectionWhileProviderSettingsWait(clearSelection: Bool) async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "create-admission-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let (database, first, second, source) = try await Task.detached {
                let database = try AppDatabaseManager(path: ":memory:")
                let first = WorkspaceRecord(id: .v7(), path: nil, name: "First", createdAt: .now, lastOpenedAt: .now)
                let second = WorkspaceRecord(id: .v7(), path: nil, name: "Second", createdAt: .now, lastOpenedAt: .now)
                try await database.dbQueue.write { db in
                    try first.insert(db)
                    try second.insert(db)
                }
                let service = BackupService(dbQueue: database.dbQueue, applicationSupportURL: root.appending(path: "source"))
                return try await (database, first, second, service.createGeneration(workspaceIds: [first.id]))
            }.value
            let model = BackupSettingsViewModel(dbQueue: database.dbQueue, applicationSupportURL: root.appending(path: "target"))
            let account = ProviderAccount.google(connectionID: .v7())
            let repository = try await providerSettingsRepository(accounts: [account])
            let suite = "BackupAdmission.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let storage = BackupStorageModel(defaults: defaults, repository: repository, providerChangeNotifications: []) { _ in nil }
            storage.select(account)
            #expect(await pollUntil { !storage.isBusy && storage.errorMessage != nil })
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let (started, continuation) = AsyncStream<Void>.makeStream()
            let blocker = Task.detached {
                try await repository.dbQueue.write { _ in
                    continuation.yield(())
                    release.wait()
                }
            }
            for await _ in started {
                break
            }
            model.selectedWorkspaceIds = [first.id]
            let creation = Task { await model.createBackup(using: storage) }
            #expect(await pollUntil { storage.isBusy })
            #expect(model.isBusy)
            // Even another caller changing selection cannot rewrite the accepted request.
            model.selectedWorkspaceIds = clearSelection ? [] : [second.id]
            let imported = await model.importBackup(from: source.fileURL)
            #expect(imported == nil)
            release.signal()
            try await blocker.value
            let generation = try #require(await creation.value)
            #expect(generation.metadata?.workspaces.map(\.id) == [first.id])
            #expect(model.generations.isEmpty)
            #expect(!model.isBusy)
            #expect(storage.errorMessage == ProviderStorageError.authorizationRequired.localizedDescription)
        }

        @Test(arguments: [false, true], [false, true])
        func dismissalCleansTransferCopiesIncludingLateResults(transferCopy: Bool, beforeAdmission: Bool) async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "restore-session-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let (database, source) = try await Task.detached {
                let database = try AppDatabaseManager(path: ":memory:")
                let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Backup", createdAt: .now, lastOpenedAt: .now)
                try await database.dbQueue.write { try workspace.insert($0) }
                let service = BackupService(dbQueue: database.dbQueue, applicationSupportURL: root.appending(path: "source"))
                return try await (database, service.createGeneration(workspaceIds: [workspace.id]))
            }.value
            let model = BackupSettingsViewModel(dbQueue: database.dbQueue, applicationSupportURL: root.appending(path: "target"))
            let service = try #require(model.backupService)
            let generation = try await service.importGeneration(from: source.fileURL)
            let revision = model.restoreRevision
            if beforeAdmission { await model.dismissRestore().value }
            await model.beginRestore(generation, transferCopy: transferCopy, revision: revision)
            if !beforeAdmission {
                #expect(model.restoreGeneration == generation)
                await model.dismissRestore().value
            }
            #expect(model.restoreGeneration == nil)
            #expect(model.restoreRevision != revision)
            #expect(try await service.listGenerations().count == (transferCopy ? 0 : 1))

            // The same model can accept a fresh session after cancellation.
            let retry = try await service.importGeneration(from: source.fileURL)
            await model.beginRestore(retry, transferCopy: true, revision: model.restoreRevision)
            #expect(model.restoreGeneration == retry)
            let overlapping = try await service.importGeneration(from: source.fileURL)
            await model.beginRestore(overlapping, transferCopy: true, revision: model.restoreRevision)
            #expect(model.restoreGeneration == retry)
            #expect(try await service.listGenerations().count == (transferCopy ? 1 : 2))
            await model.dismissRestore().value
            #expect(try await service.listGenerations().count == (transferCopy ? 0 : 1))
        }
    }
#endif
