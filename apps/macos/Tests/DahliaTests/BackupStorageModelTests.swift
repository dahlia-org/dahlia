import DahliaRuntimeSupport
import Foundation
import GRDB
@testable import Dahlia

#if canImport(Testing)
    import Testing

    /// A destination whose listing can be held until the test releases it.
    private actor FakeStorage: ProviderStorage {
        private(set) var files: [ProviderStorageFile]
        private(set) var uploads: [String] = []
        private(set) var listCalls = 0
        /// Listings that finished; the caller's continuation is queued before this count can be read.
        private(set) var listReturns = 0
        private var uploadError: (any Error)?
        private var failListingAfter: Int?
        private var held = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var downloadURL: URL?
        private var downloadWaiter: CheckedContinuation<Void, Never>?
        private(set) var downloadCalls = 0

        init(files: [String] = [], holdsListing: Bool = false, uploadError: (any Error)? = nil) {
            self.files = files.map { ProviderStorageFile(id: UUID().uuidString, name: $0, size: nil, modifiedAt: nil) }
            held = holdsListing
            self.uploadError = uploadError
        }

        func list(directory _: String) async throws -> [ProviderStorageFile] {
            listCalls += 1
            if held { await withCheckedContinuation { waiters.append($0) } }
            listReturns += 1
            if let failListingAfter, listCalls > failListingAfter { throw URLError(.timedOut) }
            return files
        }

        func upload(_: URL, to _: String, name: String) async throws {
            if let uploadError { throw uploadError }
            uploads.append(name)
            files.append(ProviderStorageFile(id: UUID().uuidString, name: name, size: nil, modifiedAt: nil))
        }

        func download(_: ProviderStorageFile) async throws -> URL {
            guard let downloadURL else { throw ProviderStorageError.invalidResponse }
            downloadCalls += 1
            await withCheckedContinuation { downloadWaiter = $0 }
            return downloadURL
        }

        func setDownload(_ url: URL) {
            downloadURL = url
        }

        func releaseDownload() {
            downloadWaiter?.resume()
            downloadWaiter = nil
        }

        func failListings(after calls: Int) { failListingAfter = calls }
        func holdListings() { held = true }
        func delete(_ file: ProviderStorageFile) async throws { files.removeAll { $0.id == file.id } }

        func release() {
            held = false
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    @MainActor
    struct BackupStorageModelTests {
        enum Invalidation: CaseIterable, Sendable {
            case cancel, changeDestination, signOut, reauthorize
        }

        private let suite = "BackupStorageModelTests.\(UUID())"

        private func invalidate(_ model: BackupStorageModel, by change: Invalidation, accountID: UUID) async {
            switch change {
            case .cancel: model.cancel()
            case .changeDestination: model.select(nil)
            case .reauthorize: GoogleSignInAdapter.invalidateStorageAuthorization(accountID: accountID)
            case .signOut:
                NotificationCenter.default.post(
                    name: GoogleAuthSessionKind.calendar.forAccount(accountID).sessionDidChangeNotification,
                    object: GoogleAuthSessionChangeReason.disconnected
                )
                #expect(await pollUntil { model.needsAuthorization && !model.isBusy })
            }
        }

        private func model(_ storages: [ProviderAccount: FakeStorage]) async throws -> (BackupStorageModel, UserDefaults, MeetingRepository) {
            let defaults = try #require(UserDefaults(suiteName: suite))
            let repository = try await providerSettingsRepository(accounts: Array(storages.keys))
            return (
                BackupStorageModel(defaults: defaults, repository: repository, providerChangeNotifications: []) { storages[$0] },
                defaults,
                repository
            )
        }

        private func generation(named name: String) throws -> BackupGeneration {
            let url = try temporaryBackupFile(named: name)
            return BackupGeneration(fileURL: url, metadata: nil, fileSize: 7, validationError: nil)
        }

        @Test
        func uploadSkipsABackupAlreadyInTheDestination() async throws {
            let account = ProviderAccount.google(connectionID: .v7())
            let storage = FakeStorage(files: ["Dahlia-same.tar.gz"])
            let (model, defaults, _) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            model.select(account)
            #expect(await pollUntil { !model.isBusy && model.files.count == 1 })
            let generation = try generation(named: "Dahlia-same.tar.gz")
            defer { try? FileManager.default.removeItem(at: generation.fileURL.deletingLastPathComponent()) }

            await model.upload(generation)

            #expect(await storage.uploads.isEmpty)
            #expect(model.statusMessage == L10n.backupStorageAlreadyUploaded)
            #expect(defaults.string(forKey: BackupStorageDestination.userDefaultsKey) == account.connectionID.uuidString)
        }

        @Test
        func uploadSendsANewBackupAndListsTheDestinationAgain() async throws {
            let account = ProviderAccount.databricks(connectionID: .v7())
            let storage = FakeStorage()
            let (model, defaults, _) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            model.select(account)
            #expect(await pollUntil { await storage.listCalls > 0 && !model.isBusy })
            let generation = try generation(named: "Dahlia-new.tar.gz")
            defer { try? FileManager.default.removeItem(at: generation.fileURL.deletingLastPathComponent()) }

            await model.upload(generation)

            #expect(await storage.uploads == ["Dahlia-new.tar.gz"])
            #expect(model.files.map(\.name) == ["Dahlia-new.tar.gz"])
            #expect(model.statusMessage == L10n.backupStorageUploaded)
        }

        @Test
        func aFailedUploadIsReportedAndLeavesTheLocalGeneration() async throws {
            let account = ProviderAccount.databricks(connectionID: .v7())
            let storage = FakeStorage(uploadError: ProviderStorageError.fileTooLarge)
            let (model, defaults, _) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            model.select(account)
            #expect(await pollUntil { await storage.listCalls > 0 && !model.isBusy })
            let generation = try generation(named: "Dahlia-large.tar.gz")
            defer { try? FileManager.default.removeItem(at: generation.fileURL.deletingLastPathComponent()) }

            await model.upload(generation)

            #expect(model.errorMessage == ProviderStorageError.fileTooLarge.localizedDescription)
            #expect(!model.isBusy)
            #expect(FileManager.default.fileExists(atPath: generation.fileURL.path))
        }

        @Test
        func creationOwnsTheUploadSlotBeforeLocalWorkStarts() async throws {
            let account = ProviderAccount.google(connectionID: .v7())
            let storage = FakeStorage()
            let (model, defaults, _) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            model.select(account)
            #expect(await pollUntil { await storage.listCalls > 0 && !model.isBusy })
            let generation = try generation(named: "Dahlia-created.tar.gz")
            defer { try? FileManager.default.removeItem(at: generation.fileURL.deletingLastPathComponent()) }
            let (stream, continuation) = AsyncStream<BackupGeneration>.makeStream()
            var creationStarted = false
            let creation = Task {
                await model.createBackup {
                    creationStarted = true
                    for await generation in stream {
                        return generation
                    }
                    return nil
                }
            }
            #expect(await pollUntil { creationStarted })
            #expect(model.isBusy)
            let calls = await storage.listCalls
            await model.refresh()
            #expect(await storage.listCalls == calls)
            continuation.yield(generation)
            continuation.finish()
            await creation.value
            #expect(await storage.uploads == ["Dahlia-created.tar.gz"])
            #expect(model.statusMessage == L10n.backupStorageUploaded)
        }

        @Test(arguments: [false, true])
        func creationDiscardsTheLocalCopyAfterEveryUploadAttempt(uploadFails: Bool) async throws {
            let account = ProviderAccount.google(connectionID: .v7())
            let storage = FakeStorage(uploadError: uploadFails ? ProviderStorageError.fileTooLarge : nil)
            let (model, defaults, _) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            model.select(account)
            #expect(await pollUntil { await storage.listCalls > 0 && !model.isBusy })
            let generation = try generation(named: "Dahlia-hidden.tar.gz")
            defer { try? FileManager.default.removeItem(at: generation.fileURL.deletingLastPathComponent()) }
            var discarded: [BackupGeneration] = []
            await model.createBackup {
                generation
            } discard: {
                discarded.append($0)
            }
            #expect(discarded == [generation])
            #expect(await storage.uploads == (uploadFails ? [] : ["Dahlia-hidden.tar.gz"]))
            #expect((model.errorMessage != nil) == uploadFails)
        }

        @Test(arguments: [false, true])
        func destinationChangesDoNotChangeTheCreatedArchivesOwnership(startsRemote: Bool) async throws {
            let account = ProviderAccount.google(connectionID: .v7())
            let storage = FakeStorage()
            let (model, defaults, _) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            if startsRemote {
                model.select(account)
                #expect(await pollUntil { await storage.listCalls > 0 && !model.isBusy })
            }
            let generation = try generation(named: "Dahlia-owned.tar.gz")
            defer { try? FileManager.default.removeItem(at: generation.fileURL.deletingLastPathComponent()) }
            var resume: CheckedContinuation<BackupGeneration?, Never>?
            var discarded: [BackupGeneration] = []
            let creation = Task {
                await model.createBackup {
                    await withCheckedContinuation { resume = $0 }
                } discard: {
                    discarded.append($0)
                }
            }
            #expect(await pollUntil { resume != nil })
            model.select(startsRemote ? nil : account)
            resume?.resume(returning: generation)
            await creation.value
            #expect(discarded == (startsRemote ? [generation] : []))
            #expect(await storage.uploads.isEmpty)
        }

        @Test(arguments: [false, true])
        func destinationSetupFailureStillKeepsTheCreatedLocalGeneration(settingsReadFails: Bool) async throws {
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let account = ProviderAccount.databricks(connectionID: .v7())
            let repository = try await providerSettingsRepository(accounts: [account])
            if settingsReadFails {
                try await repository.dbQueue.write { db in
                    try db.execute(sql: "UPDATE provider_accounts SET settingsJSON = ?", arguments: [#"{"databricks":true}"#])
                }
            }
            let model = BackupStorageModel(defaults: defaults, repository: repository, providerChangeNotifications: []) { _ in
                throw ProviderStorageError.schemaNotConfigured
            }
            model.select(account)
            #expect(await pollUntil { !model.isBusy })
            let generation = try generation(named: "Dahlia-local.tar.gz")
            defer { try? FileManager.default.removeItem(at: generation.fileURL.deletingLastPathComponent()) }
            var created = false
            await model.createBackup { created = true
                return generation
            }
            #expect(created)
            if settingsReadFails {
                #expect(model.errorMessage != nil)
            } else {
                #expect(model.errorMessage == ProviderStorageError.schemaNotConfigured.localizedDescription)
            }
            #expect(FileManager.default.fileExists(atPath: generation.fileURL.path))
        }

        @Test(arguments: Invalidation.allCases)
        func cancellingCreationKeepsTheLocalGenerationWithoutUploading(_ change: Invalidation) async throws {
            let account = ProviderAccount.google(connectionID: .v7())
            let storage = FakeStorage()
            let (model, defaults, _) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            model.select(account)
            #expect(await pollUntil { await storage.listCalls > 0 && !model.isBusy })
            let generation = try generation(named: "Dahlia-local-only.tar.gz")
            defer { try? FileManager.default.removeItem(at: generation.fileURL.deletingLastPathComponent()) }
            let (stream, continuation) = AsyncStream<BackupGeneration>.makeStream()
            var creationStarted = false
            let creation = Task {
                await model.createBackup {
                    creationStarted = true
                    for await generation in stream {
                        return generation
                    }
                    return nil
                }
            }
            #expect(await pollUntil { creationStarted })
            await invalidate(model, by: change, accountID: account.connectionID)
            continuation.yield(generation)
            continuation.finish()
            await creation.value
            #expect(await storage.uploads.isEmpty)
            #expect(FileManager.default.fileExists(atPath: generation.fileURL.path))
        }

        @Test(arguments: Invalidation.allCases)
        func cancellationBetweenPreflightAndUploadNeverSendsTheFile(_ change: Invalidation) async throws {
            let account = ProviderAccount.google(connectionID: .v7())
            let storage = FakeStorage()
            let (model, defaults, _) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            model.select(account)
            #expect(await pollUntil { await storage.listCalls > 0 && !model.isBusy })
            let calls = await storage.listCalls
            await storage.holdListings()
            let generation = try generation(named: "Dahlia-cancelled.tar.gz")
            defer { try? FileManager.default.removeItem(at: generation.fileURL.deletingLastPathComponent()) }
            let upload = Task { await model.upload(generation) }
            #expect(await pollUntil { await storage.listCalls > calls })
            await invalidate(model, by: change, accountID: account.connectionID)
            await storage.release()
            await upload.value
            #expect(await storage.uploads.isEmpty)
            #expect(model.statusMessage == nil)
        }

        @Test(arguments: Invalidation.allCases, [false, true])
        func cancelledDownloadIsNotImported(_ change: Invalidation, afterImport: Bool) async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "cancelled-import-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let (generation, service) = try await Task.detached {
                let database = try AppDatabaseManager(path: ":memory:")
                let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Backup", createdAt: .now, lastOpenedAt: .now)
                try await database.dbQueue.write { try workspace.insert($0) }
                let source = BackupService(dbQueue: database.dbQueue, applicationSupportURL: root.appending(path: "source"))
                let generation = try await source.createGeneration(workspaceIds: [workspace.id])
                let target = BackupService(dbQueue: database.dbQueue, applicationSupportURL: root.appending(path: "target"))
                return (generation, target)
            }.value
            let account = ProviderAccount.google(connectionID: .v7())
            let storage = FakeStorage(files: [generation.fileURL.lastPathComponent])
            let (model, defaults, _) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            model.select(account)
            #expect(await pollUntil { !model.isBusy && model.files.count == 1 })
            let file = try #require(model.files.first)
            await storage.setDownload(generation.fileURL)
            let download = Task { await model.download(file, into: service) }
            #expect(await pollUntil { await storage.downloadCalls == 1 })
            if afterImport {
                await storage.holdListings()
                await storage.releaseDownload()
                #expect(await pollUntil { await storage.listCalls == 2 })
                #expect(try await service.listGenerations().count == 1)
            }
            await invalidate(model, by: change, accountID: account.connectionID)
            await storage.releaseDownload()
            await storage.release()
            let result = await download.value
            #expect(result == nil)
            #expect(try await service.listGenerations().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: generation.fileURL.path))
        }

        @Test(arguments: [GoogleSignInError.noPreviousSignIn, .reauthenticationRequired])
        func expiredGoogleCredentialsOfferReauthorization(_ error: GoogleSignInError) async throws {
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let account = ProviderAccount.google(connectionID: .v7())
            let repository = try await providerSettingsRepository(accounts: [account])
            let model = BackupStorageModel(defaults: defaults, repository: repository, providerChangeNotifications: []) { _ in throw error }
            model.select(account)
            #expect(await pollUntil { !model.isBusy && model.errorMessage != nil })
            #expect(model.needsAuthorization)
        }

        @Test(arguments: [401, 403, 500])
        func onlyGoogleUnauthorizedResponsesOfferReauthorization(_ status: Int) async throws {
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let account = ProviderAccount.google(connectionID: .v7())
            let repository = try await providerSettingsRepository(accounts: [account])
            let model = BackupStorageModel(defaults: defaults, repository: repository, providerChangeNotifications: []) { _ in
                throw ProviderStorageError.requestFailed(statusCode: status, message: "failure")
            }
            model.select(account)
            #expect(await pollUntil { !model.isBusy && model.errorMessage != nil })
            #expect(model.needsAuthorization == (status == 401))
        }

        @Test
        func switchingTheDestinationDiscardsTheEarlierListing() async throws {
            let first = ProviderAccount.google(connectionID: .v7())
            let second = ProviderAccount.databricks(connectionID: .v7())
            let slow = FakeStorage(files: ["Dahlia-first.tar.gz"], holdsListing: true)
            let fast = FakeStorage(files: ["Dahlia-second.tar.gz"])
            let (model, defaults, _) = try await model([first: slow, second: fast])
            defer { defaults.removePersistentDomain(forName: suite) }
            model.select(first)
            #expect(await pollUntil { await slow.listCalls == 1 })

            model.select(second)
            #expect(await pollUntil { model.files.map(\.name) == ["Dahlia-second.tar.gz"] && !model.isBusy })
            NotificationCenter.default.post(
                name: GoogleAuthSessionKind.calendar.forAccount(first.connectionID).sessionDidChangeNotification,
                object: GoogleAuthSessionChangeReason.disconnected
            )
            await slow.release()
            #expect(await pollUntil { await slow.listReturns == 1 })
            await model.refresh()

            #expect(model.files.map(\.name) == ["Dahlia-second.tar.gz"])
            #expect(model.destination == second)
            #expect(!model.needsAuthorization)
        }

        @Test
        func cancellingDropsTheRunningOperationsResult() async throws {
            let account = ProviderAccount.google(connectionID: .v7())
            let storage = FakeStorage(files: ["Dahlia-late.tar.gz"], holdsListing: true)
            let (model, defaults, _) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            model.select(account)
            #expect(await pollUntil { await storage.listCalls == 1 && model.isBusy })

            model.cancel()
            #expect(!model.isBusy)
            await storage.release()
            #expect(await pollUntil { await storage.listReturns == 1 })
            #expect(model.files.isEmpty)
            await model.refresh()

            #expect(model.files.map(\.name) == ["Dahlia-late.tar.gz"])
            model.select(nil)
            #expect(model.files.isEmpty)
            #expect(defaults.string(forKey: BackupStorageDestination.userDefaultsKey) == nil)
        }

        @Test(arguments: ["main.other", ""])
        func editingOrClearingLocationDuringPreflightNeverUploads(_ value: String) async throws {
            let account = ProviderAccount.databricks(connectionID: .v7())
            let storage = FakeStorage()
            let (model, defaults, repository) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            try await DatabricksCatalogSchema.save(DatabricksCatalogSchema("main.dahlia"), connectionID: account.connectionID, repository: repository)
            model.select(account)
            #expect(await pollUntil { await storage.listCalls > 0 && !model.isBusy })
            let calls = await storage.listCalls
            await storage.holdListings()
            let generation = try generation(named: "Dahlia-location.tar.gz")
            defer { try? FileManager.default.removeItem(at: generation.fileURL.deletingLastPathComponent()) }
            let upload = Task { await model.upload(generation) }
            #expect(await pollUntil { await storage.listCalls > calls })
            // No notification: admission must validate the actual setting even before observers run.
            try await setDatabricksLocationWithoutNotification(value, id: account.connectionID, repository: repository)
            await storage.release()
            await upload.value
            #expect(await storage.uploads.isEmpty)
            #expect(FileManager.default.fileExists(atPath: generation.fileURL.path))
            await model.refresh()
            #expect(model.errorMessage == nil)
        }

        @Test(arguments: ["Other backups", ""])
        func editingOrResettingGoogleFolderDuringPreflightNeverUploads(_ value: String) async throws {
            let account = ProviderAccount.google(connectionID: .v7())
            let storage = FakeStorage()
            let (model, defaults, repository) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            try await GoogleDriveStorageLocation.save(
                #require(GoogleDriveStorageLocation("Original")),
                accountID: account.connectionID,
                repository: repository
            )
            model.select(account)
            #expect(await pollUntil { await storage.listCalls > 0 && !model.isBusy })
            let calls = await storage.listCalls
            await storage.holdListings()
            let generation = try generation(named: "Dahlia-location.tar.gz")
            defer { try? FileManager.default.removeItem(at: generation.fileURL.deletingLastPathComponent()) }
            let upload = Task { await model.upload(generation) }
            #expect(await pollUntil { await storage.listCalls > calls })
            // No notification: admission must validate the actual setting even before observers run.
            try await setGoogleDriveFolderWithoutNotification(value, id: account.connectionID, repository: repository)
            await storage.release()
            await upload.value
            #expect(await storage.uploads.isEmpty)
            #expect(FileManager.default.fileExists(atPath: generation.fileURL.path))
            await model.refresh()
            #expect(model.errorMessage == nil)
        }

        @Test
        func editingLocationDuringLocalCreationKeepsTheLocalGenerationOnly() async throws {
            let account = ProviderAccount.databricks(connectionID: .v7())
            let storage = FakeStorage()
            let (model, defaults, repository) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            model.select(account)
            #expect(await pollUntil { await storage.listCalls > 0 && !model.isBusy })
            let generation = try generation(named: "Dahlia-local-context.tar.gz")
            defer { try? FileManager.default.removeItem(at: generation.fileURL.deletingLastPathComponent()) }
            await model.createBackup {
                do {
                    try await setDatabricksLocationWithoutNotification("main.changed", id: account.connectionID, repository: repository)
                } catch { Issue.record(error) }
                return generation
            }
            #expect(await storage.uploads.isEmpty)
            #expect(FileManager.default.fileExists(atPath: generation.fileURL.path))
        }

        @Test(arguments: [true, false])
        func selectedDatabricksChangesInvalidateTheOwnedOperation(signIn: Bool) async throws {
            let account = ProviderAccount.databricks(connectionID: .v7())
            let storage = FakeStorage()
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let repository = try await providerSettingsRepository(accounts: [account])
            var factoryCalls = 0
            let model = BackupStorageModel(defaults: defaults, repository: repository, providerChangeNotifications: []) { _ in
                factoryCalls += 1
                return storage
            }
            model.select(account)
            #expect(await pollUntil { factoryCalls == 1 && !model.isBusy })
            await storage.holdListings()
            let calls = await storage.listCalls
            let generation = try generation(named: "Dahlia-stale.tar.gz")
            defer { try? FileManager.default.removeItem(at: generation.fileURL.deletingLastPathComponent()) }
            let upload = Task { await model.upload(generation) }
            #expect(await pollUntil { await storage.listCalls > calls })
            let before = factoryCalls
            if signIn {
                NotificationCenter.default.post(
                    name: DatabricksOAuthService.storageAuthorizationDidChange(connectionID: account.connectionID),
                    object: nil
                )
            } else {
                try await DatabricksCatalogSchema.save(
                    DatabricksCatalogSchema("main.changed"),
                    connectionID: account.connectionID,
                    repository: repository
                )
            }
            #expect(await pollUntil { factoryCalls > before })
            await storage.release()
            await upload.value
            #expect(await pollUntil { !model.isBusy })
            #expect(await storage.uploads.isEmpty)
            await model.upload(generation)
            #expect(await storage.uploads == [generation.fileURL.lastPathComponent])
        }

        @Test
        func recoveryListExcludesOrdinaryFilesAndRejectsTheirHandles() async throws {
            let account = ProviderAccount.databricks(connectionID: .v7())
            let storage = FakeStorage(files: ["report.csv", "Dahlia-valid.tar.gz", "Dahlia-upper.TAR.GZ"])
            let (model, defaults, _) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            model.select(account)
            #expect(await pollUntil { !model.isBusy && model.files.count == 2 })
            #expect(model.files.map(\.name) == ["Dahlia-valid.tar.gz", "Dahlia-upper.TAR.GZ"])
            let ordinary = try #require(await storage.files.first { $0.name == "report.csv" })
            await model.delete(ordinary)
            #expect(await storage.files.contains(ordinary))
            let service = try await Task.detached {
                let database = try AppDatabaseManager(path: ":memory:")
                return BackupService(
                    dbQueue: database.dbQueue,
                    applicationSupportURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
                )
            }.value
            await model.download(ordinary, into: service)
            #expect(await storage.downloadCalls == 0)
        }

        @Test(arguments: [true, false])
        func downloadedArchiveIsImportedOnlyForTheCurrentLocation(locationChanges: Bool) async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "storage-import-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let (generation, service) = try await Task.detached {
                let database = try AppDatabaseManager(path: ":memory:")
                let workspace = WorkspaceRecord(id: .v7(), path: nil, name: "Backup", createdAt: .now, lastOpenedAt: .now)
                try await database.dbQueue.write { try workspace.insert($0) }
                let source = BackupService(dbQueue: database.dbQueue, applicationSupportURL: root.appending(path: "source"))
                let generation = try await source.createGeneration(workspaceIds: [workspace.id])
                return (generation, BackupService(dbQueue: database.dbQueue, applicationSupportURL: root.appending(path: "target")))
            }.value
            let account = ProviderAccount.databricks(connectionID: .v7())
            let storage = FakeStorage(files: [generation.fileURL.lastPathComponent])
            let (model, defaults, repository) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            model.select(account)
            #expect(await pollUntil { !model.isBusy && model.files.count == 1 })
            await storage.setDownload(generation.fileURL)
            await storage.failListings(after: storage.listCalls)
            let file = try #require(model.files.first)
            let download = Task { await model.download(file, into: service) }
            #expect(await pollUntil { await storage.downloadCalls == 1 })
            if locationChanges { try await setDatabricksLocationWithoutNotification("main.changed", id: account.connectionID, repository: repository)
            }
            await storage.releaseDownload()
            let imported = await download.value
            #expect(try await service.listGenerations().count == (locationChanges ? 0 : 1))
            #expect((imported != nil) == !locationChanges)
            #expect(model.statusMessage == nil)
            if !locationChanges { #expect(model.errorMessage == URLError(.timedOut).localizedDescription) }
            #expect(!FileManager.default.fileExists(atPath: generation.fileURL.path))
        }

        @Test(arguments: [true, false])
        func completedTransfersKeepTheirSuccessWhenRefreshFails(upload: Bool) async throws {
            let account = ProviderAccount.databricks(connectionID: .v7())
            let storage = FakeStorage(files: ["Dahlia-existing.tar.gz"])
            let (model, defaults, _) = try await model([account: storage])
            defer { defaults.removePersistentDomain(forName: suite) }
            model.select(account)
            #expect(await pollUntil { !model.isBusy && model.files.count == 1 })
            let calls = await storage.listCalls
            await storage.failListings(after: calls + (upload ? 1 : 0))
            if upload {
                let generation = try generation(named: "Dahlia-completed.tar.gz")
                defer { try? FileManager.default.removeItem(at: generation.fileURL.deletingLastPathComponent()) }
                await model.upload(generation)
                #expect(await storage.uploads == [generation.fileURL.lastPathComponent])
            } else {
                try await model.delete(#require(model.files.first))
                #expect(await storage.files.isEmpty)
            }
            #expect(model.statusMessage == (upload ? L10n.backupStorageUploaded : L10n.backupStorageDeleted))
            #expect(model.errorMessage == URLError(.timedOut).localizedDescription)
        }

        @Test
        func aDatabricksConnectionWithoutAStorageLocationAsksForOne() async throws {
            let id = UUID.v7()
            let suite = "BackupStorageLocation.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            try await ProviderAccountDirectory.$connections.withValue([.init(
                id: id,
                workspaceURL: #require(URL(string: "https://dbc.example"))
            )]) { () async throws in
                let repository = try await providerSettingsRepository(accounts: [.databricks(connectionID: id)])
                await #expect(throws: ProviderStorageError.schemaNotConfigured) {
                    try await ProviderAccount.databricks(connectionID: id).storage(repository: repository)
                }
                try await DatabricksCatalogSchema.save(DatabricksCatalogSchema("main.dahlia"), connectionID: id, repository: repository)
                #expect(try await DatabricksCatalogSchema.load(connectionID: id, repository: repository)?.description == "main.dahlia")
                #expect(ProviderAccount.databricks(connectionID: id).capabilities.contains(.storage))
                #expect(!ProviderAccount.dahlia(connectionID: id).capabilities.contains(.storage))
            }
        }
    }
#endif
