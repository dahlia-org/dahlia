import Foundation
import Observation

/// Where backups go besides this Mac: one provider account that offers storage, or none.
enum BackupStorageDestination {
    static let userDefaultsKey = "backupStorageAccount"
    /// Backups use this folder of the destination's storage; other data gets its own folder.
    static let directory = "backup"

    static func current(defaults: UserDefaults = .standard) -> ProviderAccount? {
        guard let id = defaults.string(forKey: userDefaultsKey).flatMap(UUID.init(uuidString:)) else { return nil }
        return ProviderAccountDirectory.accounts.first { $0.connectionID == id && $0.capabilities.contains(.storage) }
    }

    static func save(_ account: ProviderAccount?, defaults: UserDefaults = .standard) {
        defaults.set(account?.connectionID.uuidString, forKey: userDefaultsKey)
    }
}

extension ProviderAccount {
    /// The account's storage, or nil when it offers none.
    @MainActor
    func storage(repository: MeetingRepository? = nil) async throws -> (any ProviderStorage)? {
        switch self {
        case let .google(id):
            let expected = ProviderAccountDirectory.googleConnections().first { $0.id == id }?.account.id
            return try await GoogleDriveStorage(
                accountID: id, signIn: GoogleSignInAdapter(accountID: id, expectedAccountID: expected), repository: repository
            )
        case let .databricks(id):
            guard let host = ProviderAccountDirectory.databricksConnections().first(where: { $0.id == id })?.workspaceURL else { return nil }
            guard let location = try await DatabricksCatalogSchema.load(connectionID: id, repository: repository) else {
                throw ProviderStorageError.schemaNotConfigured
            }
            let authorization = try await DatabricksOAuthService.shared.storageAuthorization(connectionID: id)
            return DatabricksVolumeStorage(host: host, location: location, authorization: authorization) { @MainActor in
                guard try await DatabricksCatalogSchema.load(connectionID: id, repository: repository) == location else {
                    throw CancellationError()
                }
            }
        case .dahlia:
            return nil
        }
    }
}

extension ProviderAccount {
    /// Where the account keeps backups, for display. Nil while a Databricks connection has no catalog and schema.
    /// Without the network, the Databricks volume shows its name pattern instead of the user's ID.
    @MainActor
    func backupLocationDescription() async throws -> String? {
        switch self {
        case let .google(id):
            return try await L10n.storageGoogleDrivePath(GoogleDriveStorageLocation.load(accountID: id).folderName)
        case let .databricks(id):
            guard let location = try await DatabricksCatalogSchema.load(connectionID: id) else { return nil }
            let fallback = L10n.storageDatabricksVolumePath(location.catalog, location.schema)
            guard let storage = try? await storage() as? DatabricksVolumeStorage else { return fallback }
            return await (try? storage.backupPath()) ?? fallback
        case .dahlia:
            return nil
        }
    }
}

struct BackupStorageOption: Identifiable, Equatable {
    let account: ProviderAccount
    let name: String
    var id: UUID { account.connectionID }
}

/// The backups in the selected destination, and moving generations between it and this Mac. Every operation lists
/// the destination again afterward, and changing the destination or cancelling discards results still in flight.
@Observable
@MainActor
final class BackupStorageModel {
    private(set) var options: [BackupStorageOption] = []
    private(set) var destination: ProviderAccount?
    private(set) var files: [ProviderStorageFile] = []
    private(set) var isBusy = false
    private(set) var needsAuthorization = false
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private let repository: MeetingRepository?
    private let makeStorage: @MainActor (ProviderAccount) async throws -> (any ProviderStorage)?
    private var storage: (any ProviderStorage)?
    private var revision = 0
    private var operation: Task<Void, Never>?
    private var authorizationObserver: GoogleAuthSessionObserver?
    private var locationObserver: GoogleAuthSessionObserver?
    private var operationGoogleLocation: GoogleDriveStorageLocation?
    private var operationLocation: DatabricksCatalogSchema?
    private var operationSettingsError: (any Error)?
    private var operationAuthorizationGeneration: UUID?
    private var providerObservers: [GoogleAuthSessionObserver] = []

    init(
        defaults: UserDefaults = .standard,
        repository: MeetingRepository? = nil,
        providerChangeNotifications: [Notification.Name] = [GoogleProviderAccount.didChange, .databricksConnectionDidChange],
        makeStorage: (@MainActor (ProviderAccount) async throws -> (any ProviderStorage)?)? = nil
    ) {
        self.defaults = defaults
        self.repository = repository
        self.makeStorage = makeStorage ?? { try await $0.storage(repository: repository) }
        destination = BackupStorageDestination.current(defaults: defaults)
        observeAuthorization()
        providerObservers = providerChangeNotifications.map { name in
            GoogleAuthSessionObserver(notificationName: name) { [weak self] _ in
                await self?.reloadOptions()
            }
        }
    }

    func reloadOptions() async {
        let databricks = await (try? DatabricksOAuthService.shared.connections()) ?? []
        options = ProviderAccountDirectory.googleConnections().map {
            BackupStorageOption(account: .google(connectionID: $0.id), name: $0.displayName)
        } + databricks.map { BackupStorageOption(account: .databricks(connectionID: $0.id), name: $0.displayName) }
        let current = BackupStorageDestination.current(defaults: defaults)
        if current != destination { select(current) }
    }

    func select(_ account: ProviderAccount?) {
        BackupStorageDestination.save(account, defaults: defaults)
        destination = account
        storage = nil
        cancel()
        observeAuthorization()
        files = []
        guard account != nil else { return }
        Task { await refresh() }
    }

    /// Transfers can outlive the settings view, so their owner also owns sign-out invalidation.
    private func observeAuthorization() {
        authorizationObserver = nil
        locationObserver = nil
        if case let .databricks(id) = destination {
            let invalidate: @MainActor @Sendable (Bool) async -> Void = { [weak self] _ in
                guard let self, destination == .databricks(connectionID: id) else { return }
                cancel()
                storage = nil
                files = []
                await refresh()
            }
            locationObserver = GoogleAuthSessionObserver(
                notificationName: DatabricksCatalogSchema.didChange(connectionID: id), handler: invalidate
            )
            authorizationObserver = GoogleAuthSessionObserver(
                notificationName: DatabricksOAuthService.storageAuthorizationDidChange(connectionID: id), handler: invalidate
            )
        }
        guard case let .google(id) = destination else { return }
        let account = destination
        locationObserver = GoogleAuthSessionObserver(notificationName: GoogleDriveStorageLocation.didChange(accountID: id)) { [weak self] _ in
            guard let self, destination == account else { return }
            cancel()
            storage = nil
            files = []
            await refresh()
        }
        authorizationObserver = GoogleAuthSessionObserver(
            notificationName: GoogleAuthSessionKind.calendar.forAccount(id).sessionDidChangeNotification
        ) { [weak self] disconnected in
            guard let self, destination == account else { return }
            cancel()
            storage = nil
            files = []
            needsAuthorization = disconnected
            if !disconnected { Task { await self.refresh() } }
        }
    }

    /// Stops the running operation; its result, if any arrives, is discarded.
    func cancel() {
        revision += 1
        operation?.cancel()
        operation = nil
        isBusy = false
        needsAuthorization = false
        statusMessage = nil
        errorMessage = nil
    }

    func refresh() async {
        await run { nil }
    }

    /// Owns creation and upload as one operation, so another remote operation cannot consume the upload slot.
    /// Always create locally first, even if the destination needs configuration or authorization. With a destination,
    /// `discard` removes the local copy after the upload attempt, whatever its outcome: the source data stays in the
    /// database, so a failed backup is made again rather than kept hidden on this Mac.
    func createBackup(
        _ create: @escaping @MainActor () async -> BackupGeneration?,
        discard: @escaping @MainActor (BackupGeneration) async -> Void = { _ in }
    ) async {
        let isTransferCopy = destination != nil
        await run(createsLocally: true) {
            guard let generation = await create() else { return nil }
            guard isTransferCopy else { return nil }
            do {
                try await self.checkOperation()
                let message = try await self.uploadGeneration(generation)
                await discard(generation)
                return message
            } catch {
                await discard(generation)
                throw error
            }
        }
    }

    /// Uploads a local generation unless a file with its name is already there. Names carry the generation UUID and a
    /// generation never changes, so a matching name is the same backup.
    func upload(_ generation: BackupGeneration) async {
        guard destination != nil else { return }
        await run { try await self.uploadGeneration(generation) }
    }

    private func uploadGeneration(_ generation: BackupGeneration) async throws -> String {
        let storage = try await requireStorage()
        let name = generation.fileURL.lastPathComponent
        let existing = try await storage.list(directory: BackupStorageDestination.directory)
        try await checkOperation()
        guard !existing.contains(where: { $0.name == name }) else { return L10n.backupStorageAlreadyUploaded }
        try await storage.upload(generation.fileURL, to: BackupStorageDestination.directory, name: name)
        return L10n.backupStorageUploaded
    }

    /// Downloads a listed backup through the normal import validation, for the caller to restore from.
    @discardableResult
    func download(_ file: ProviderStorageFile, into service: BackupService) async -> BackupGeneration? {
        guard files.contains(file) else { return nil }
        let revision = revision
        var imported: BackupGeneration?
        await run {
            let storage = try await self.requireStorage()
            let url = try await storage.download(file)
            defer { try? FileManager.default.removeItem(at: url) }
            try await self.checkOperation()
            imported = try await service.importGeneration(from: url)
            return nil
        }
        guard let imported else { return nil }
        do {
            guard self.revision == revision else { throw CancellationError() }
            try await checkOperation()
            guard self.revision == revision else { throw CancellationError() }
            return imported
        } catch {
            try? await service.deleteGeneration(imported)
            return nil
        }
    }

    func delete(_ file: ProviderStorageFile) async {
        guard files.contains(file) else { return }
        await run {
            let storage = try await self.requireStorage()
            try await storage.delete(file)
            return L10n.backupStorageDeleted
        }
    }

    /// Asks the selected Google account again with the Drive scope; Databricks needs no extra grant.
    func authorize() async {
        guard case let .google(id) = destination else { return }
        let revision = revision
        let accounts = GoogleProviderAccountsModel.shared
        if !accounts.controllers.contains(where: { $0.id == id }) { await accounts.activate() }
        guard self.revision == revision else { return }
        guard let controller = accounts.controllers.first(where: { $0.id == id }) else { return }
        let authorized = await controller.signIn()
        guard self.revision == revision else { return }
        guard authorized else {
            errorMessage = controller.errorMessage
            return
        }
        storage = nil
        await refresh()
    }

    private func checkOperation() async throws {
        try Task.checkCancellation()
        if let operationSettingsError { throw operationSettingsError }
        if case let .databricks(id) = destination {
            guard try await DatabricksCatalogSchema.load(connectionID: id, repository: repository) == operationLocation,
                  DatabricksOAuthService.shared.storageGeneration(connectionID: id) == operationAuthorizationGeneration else {
                throw CancellationError()
            }
        }
        if case let .google(id) = destination {
            guard try await GoogleDriveStorageLocation.load(accountID: id, repository: repository) == operationGoogleLocation else {
                throw CancellationError()
            }
            try GoogleSignInAdapter.validateStorageGeneration(operationAuthorizationGeneration, accountID: id)
        }
        try await storage?.validate()
        try Task.checkCancellation()
    }

    private func requireStorage() async throws -> any ProviderStorage {
        try await checkOperation()
        if let storage { return storage }
        guard let destination, let storage = try await makeStorage(destination) else {
            throw ProviderStorageError.authorizationRequired
        }
        try await checkOperation()
        self.storage = storage
        return storage
    }

    private func run(createsLocally: Bool = false, _ body: @escaping @MainActor () async throws -> String?) async {
        guard !isBusy else { return }
        let revision = revision
        let authorizationGeneration: UUID? = if case let .databricks(id) = destination {
            DatabricksOAuthService.shared.storageGeneration(connectionID: id)
        } else if case let .google(id) = destination {
            GoogleSignInAdapter.storageGeneration(accountID: id)
        } else {
            nil
        }
        storage = nil
        isBusy = true
        statusMessage = nil
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.revision == revision { isBusy = false } }
            do {
                try Task.checkCancellation()
                operationLocation = nil
                operationGoogleLocation = nil
                operationAuthorizationGeneration = nil
                operationSettingsError = nil
                do {
                    if case let .databricks(id) = destination {
                        let location = try await DatabricksCatalogSchema.load(connectionID: id, repository: repository)
                        try Task.checkCancellation()
                        operationLocation = location
                        operationAuthorizationGeneration = authorizationGeneration
                    } else if case let .google(id) = destination {
                        let location = try await GoogleDriveStorageLocation.load(accountID: id, repository: repository)
                        try Task.checkCancellation()
                        operationGoogleLocation = location
                        operationAuthorizationGeneration = authorizationGeneration
                    }
                } catch {
                    try Task.checkCancellation()
                    if !createsLocally { throw error }
                    operationSettingsError = error
                }
                try Task.checkCancellation()
                if !createsLocally { try await checkOperation() }
                let message = try await body()
                try await checkOperation()
                guard self.revision == revision else { return }
                statusMessage = message
                let files: [ProviderStorageFile] = if destination != nil {
                    try await requireStorage().list(directory: BackupStorageDestination.directory)
                } else {
                    []
                }
                try await checkOperation()
                guard self.revision == revision else { return }
                self.files = files.filter { BackupArchive.isBackupFile(URL(fileURLWithPath: $0.name)) }
                needsAuthorization = false
            } catch {
                guard self.revision == revision else { return }
                if case .google = destination {
                    switch error {
                    case GoogleSignInError.noPreviousSignIn, GoogleSignInError.reauthenticationRequired,
                         ProviderStorageError.authorizationRequired, ProviderStorageError.requestFailed(statusCode: 401, message: _):
                        needsAuthorization = true
                    default:
                        needsAuthorization = false
                    }
                }
                errorMessage = error.localizedDescription
            }
        }
        operation = task
        await task.value
    }
}
