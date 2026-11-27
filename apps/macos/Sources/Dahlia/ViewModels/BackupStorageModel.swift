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
    func storage(defaults: UserDefaults = .standard) async throws -> (any ProviderStorage)? {
        switch self {
        case let .google(id):
            let expected = ProviderAccountDirectory.googleConnections().first { $0.id == id }?.account.id
            let adapter = GoogleSignInAdapter(accountID: id, expectedAccountID: expected)
            return GoogleDriveStorage { @MainActor in
                // A grant made before `drive.file` holds only the retired read scope, which Dahlia no longer uses.
                guard let session = try await adapter.refreshCurrentSession(), session.hasScopes(GoogleOAuthScope.drive) else {
                    throw ProviderStorageError.authorizationRequired
                }
                return session.accessToken
            }
        case let .databricks(id):
            guard let host = ProviderAccountDirectory.databricksConnections().first(where: { $0.id == id })?.workspaceURL else { return nil }
            guard let location = DatabricksStorageLocation.load(connectionID: id, defaults: defaults) else {
                throw ProviderStorageError.schemaNotConfigured
            }
            let authorization = try await DatabricksOAuthService.shared.storageAuthorization(connectionID: id)
            return DatabricksVolumeStorage(host: host, location: location, authorization: authorization) { @MainActor in
                guard DatabricksStorageLocation.load(connectionID: id, defaults: defaults) == location else {
                    throw CancellationError()
                }
            }
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
    private let makeStorage: @MainActor (ProviderAccount) async throws -> (any ProviderStorage)?
    private var storage: (any ProviderStorage)?
    private var revision = 0
    private var operation: Task<Void, Never>?
    private var authorizationObserver: GoogleAuthSessionObserver?
    private var locationObserver: GoogleAuthSessionObserver?
    private var operationLocation: DatabricksStorageLocation?
    private var operationAuthorizationGeneration: UUID?
    private var providerObservers: [GoogleAuthSessionObserver] = []

    init(
        defaults: UserDefaults = .standard,
        providerChangeNotifications: [Notification.Name] = [GoogleProviderAccount.didChange, .databricksConnectionDidChange],
        makeStorage: @escaping @MainActor (ProviderAccount) async throws -> (any ProviderStorage)? = { try await $0.storage() }
    ) {
        self.defaults = defaults
        self.makeStorage = makeStorage
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
                notificationName: DatabricksStorageLocation.didChange(connectionID: id), handler: invalidate
            )
            authorizationObserver = GoogleAuthSessionObserver(
                notificationName: DatabricksOAuthService.storageAuthorizationDidChange(connectionID: id), handler: invalidate
            )
        }
        guard case let .google(id) = destination else { return }
        let account = destination
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
    /// Always create locally first, even if the destination needs configuration or authorization.
    func createBackup(_ create: @escaping @MainActor () async -> BackupGeneration?) async {
        await run {
            guard let generation = await create() else { return nil }
            try await self.checkOperation()
            guard self.destination != nil else { return nil }
            return try await self.uploadGeneration(generation)
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

    /// Downloads a listed backup and adds it to the local generations through the normal import validation.
    func download(_ file: ProviderStorageFile, into service: BackupService) async {
        guard files.contains(file) else { return }
        await run {
            let storage = try await self.requireStorage()
            let url = try await storage.download(file)
            defer { try? FileManager.default.removeItem(at: url) }
            try await self.checkOperation()
            _ = try await service.importGeneration(from: url)
            return L10n.backupImported
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
        if case let .databricks(id) = destination {
            guard DatabricksStorageLocation.load(connectionID: id, defaults: defaults) == operationLocation,
                  DatabricksOAuthService.shared.storageGeneration(connectionID: id) == operationAuthorizationGeneration else {
                throw CancellationError()
            }
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

    private func run(_ body: @escaping @MainActor () async throws -> String?) async {
        guard !isBusy else { return }
        let revision = revision
        storage = nil
        if case let .databricks(id) = destination {
            operationLocation = DatabricksStorageLocation.load(connectionID: id, defaults: defaults)
            operationAuthorizationGeneration = DatabricksOAuthService.shared.storageGeneration(connectionID: id)
        } else {
            operationLocation = nil
            operationAuthorizationGeneration = nil
        }
        isBusy = true
        statusMessage = nil
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.revision == revision { isBusy = false } }
            do {
                try await checkOperation()
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
