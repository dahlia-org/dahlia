import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class WorkspaceAISettingsModel {
    static let shared = WorkspaceAISettingsModel()

    private(set) var workspaceID: UUID?
    var accountConnectionID: UUID? {
        didSet {
            scheduleRuntimeActivationIfChanged(oldValue, accountConnectionID)
        }
    }

    /// Provider selection belongs to the Local account on this Mac.
    var localProvider: AIAccountProvider {
        didSet { persistLocalAccountSettingsIfChanged(oldValue, localProvider) }
    }

    /// Kept for released settings. The open workspace's `databricksConnectionId` now chooses the Databricks account.
    var databricksProfile: String {
        didSet { persistLocalAccountSettingsIfChanged(oldValue, databricksProfile) }
    }

    /// Connected Databricks workspaces, oldest first. Each one is a Databricks account with its own workspaces.
    private(set) var databricksConnections: [DatabricksConnection] = []

    /// The Databricks account of the open workspace. It lists only its workspace's AI Gateway models; the Local Account
    /// lists only the subscriptions'.
    private(set) var databricksAccountConnectionID: UUID? {
        didSet {
            guard oldValue != databricksAccountConnectionID else { return }
            NotificationCenter.default.post(name: PiRuntimeService.modelsDidChange, object: nil)
        }
    }

    var isDatabricksAccount: Bool {
        isLocalAccount && databricksAccountConnectionID != nil
    }

    var generationSettings = WorkspaceGenerationSettings() {
        didSet { persistIfChanged(oldValue, generationSettings, persistsWorkspace: oldValue.outputLanguage != generationSettings.outputLanguage) }
    }

    var summaryModelID: String {
        get { generationSettings.local.model }
        set { generationSettings.local.model = newValue }
    }

    var summaryReasoningEffort: String {
        get { generationSettings.local.reasoningEffort }
        set { generationSettings.local.reasoningEffort = newValue }
    }

    var chatModelID: String { didSet { persistIfChanged(oldValue, chatModelID) } }
    var chatReasoningEffort: String { didSet { persistIfChanged(oldValue, chatReasoningEffort) } }
    private(set) var isSwitchingRuntime = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var dbQueue: DatabaseQueue?
    @ObservationIgnored private var workspaceObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var activationGeneration = 0
    @ObservationIgnored private var persistenceGeneration = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var runtimeTask: Task<Bool, Never>?
    @ObservationIgnored private let setupDefaults: UserDefaults
    @ObservationIgnored private let activateRuntime: @Sendable (WorkspaceAISettingsSnapshot) async throws -> Void
    @ObservationIgnored private let databricksService: DatabricksOAuthService
    @ObservationIgnored private var databricksObserver: NSObjectProtocol?

    init(
        setupDefaults: UserDefaults = .standard,
        activateRuntime: @escaping @Sendable (WorkspaceAISettingsSnapshot) async throws -> Void = {
            try await CodexRuntimeContextCoordinator.shared.activate($0)
        },
        databricksService: DatabricksOAuthService = .shared
    ) {
        self.setupDefaults = setupDefaults
        self.activateRuntime = activateRuntime
        self.databricksService = databricksService
        accountConnectionID = nil
        let localSettings = LocalAccountAISettings(defaults: setupDefaults)
        let restoresSetupDraft = !setupDefaults.bool(forKey: LocalAccountAISettings.migrationKey)
            && SetupTourPresentationPolicy.hasSavedProgress(in: setupDefaults)
        if restoresSetupDraft {
            localProvider = SetupTourPresentationPolicy.restoredProvider(in: setupDefaults) ?? localSettings.provider
            databricksProfile = SetupTourPresentationPolicy.restoredDatabricksProfile(in: setupDefaults)
        } else {
            localProvider = localSettings.provider
            databricksProfile = localSettings.databricksProfile
        }
        chatModelID = ""
        chatReasoningEffort = CodexReasoningEffortOption.defaultValue
        databricksObserver = NotificationCenter.default.addObserver(
            forName: .databricksConnectionDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.reloadDatabricksConnections() } }
        }
    }

    var snapshot: WorkspaceAISettingsSnapshot? {
        guard let workspaceID else { return nil }
        return snapshot(for: workspaceID)
    }

    func snapshot(for workspaceID: UUID) -> WorkspaceAISettingsSnapshot {
        WorkspaceAISettingsSnapshot(
            workspaceID: workspaceID,
            accountConnectionID: accountConnectionID,
            databricksConnectionID: databricksAccountConnectionID,
            localProvider: localProvider,
            databricksProfile: databricksProfile,
            generationSettings: workspaceID == self.workspaceID ? generationSettings : WorkspaceGenerationSettings(),
            chatModelID: chatModelID,
            chatReasoningEffort: chatReasoningEffort
        )
    }

    func generationSettings(for workspace: WorkspaceRecord) -> WorkspaceGenerationSettings {
        AccountInferenceSettings(workspace: workspace, defaults: setupDefaults)
            .generationSettings(outputLanguage: workspace.generationSettings.outputLanguage)
    }

    var isLocalAccount: Bool { accountConnectionID == nil }

    var localAccountSettings: LocalAccountAISettings {
        LocalAccountAISettings(provider: localProvider, databricksProfile: databricksProfile)
    }

    func configure(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
        observeWorkspace()
        Task { await reloadDatabricksConnections() }
    }

    /// Lists the connected Databricks workspaces with their user and workspace ID. A removed account's workspaces
    /// return to the Local Account through the `accounts` foreign key.
    func reloadDatabricksConnections() async {
        let service = databricksService
        guard let connections = try? await service.connections() else { return }
        databricksConnections = connections
        for connection in connections where connection.email == nil {
            guard let identified = try? await service.identifiedConnection(id: connection.id),
                  let index = databricksConnections.firstIndex(where: { $0.id == identified.id }) else { continue }
            databricksConnections[index] = identified
        }
    }

    /// Removes the open Databricks account's workspace connection. Its workspaces return to the Local Account.
    func signOutOfDatabricksAccount() async {
        guard let connectionID = databricksAccountConnectionID else { return }
        do {
            // Its workspaces are the Local Account's now. Its folder, with its chats, stays.
            try await databricksService.remove(connectionID: connectionID)
            CodexRuntimeContextStore.shared.accountRemoved(.databricks(connectionID: connectionID))
            setupDefaults.removeObject(forKey: AccountInferenceSettings.key(connectionID: nil, databricksConnectionID: connectionID))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The Local Account's (nil) or a Databricks account's workspace to open, created on first use so the account
    /// always has one.
    func accountWorkspace(databricksConnectionID connectionID: UUID?) async -> WorkspaceRecord? {
        guard let dbQueue else { return nil }
        var created = WorkspaceRecord(
            id: .v7(), path: nil, name: WorkspaceManagementModel.initialWorkspaceName, createdAt: .now, lastOpenedAt: .distantPast,
            databricksConnectionId: connectionID
        )
        snapshot(for: created.id).applyAISettings(to: &created)
        do {
            return try await MeetingRepository(dbQueue: dbQueue).accountWorkspace(databricksConnectionID: connectionID, creating: created)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func inheritLocalAccountSettings(from dbQueue: DatabaseQueue) async throws {
        guard !setupDefaults.bool(forKey: LocalAccountAISettings.migrationKey) else { return }
        let previousWorkspace = try await MeetingRepository(dbQueue: dbQueue).fetchLatestLocalAccountWorkspace()
        isApplying = true
        if let previousWorkspace, previousWorkspace.aiSettingsBackfilled {
            localProvider = previousWorkspace.localProvider
            databricksProfile = previousWorkspace.databricksProfile
        }
        isApplying = false
        localAccountSettings.save(to: setupDefaults)
    }

    func inheritAccountInferenceSettings(from dbQueue: DatabaseQueue) async throws {
        let workspaces = try await dbQueue.read { db in
            try WorkspaceRecord.order(Column("lastOpenedAt").desc, Column("createdAt").desc).fetchAll(db)
        }
        for workspace in workspaces {
            let key = AccountInferenceSettings.key(
                connectionID: workspace.accountConnectionId, databricksConnectionID: workspace.databricksConnectionId
            )
            guard setupDefaults.data(forKey: key) == nil else { continue }
            AccountInferenceSettings(workspace: workspace, defaults: setupDefaults).save(
                connectionID: workspace.accountConnectionId,
                databricksConnectionID: workspace.databricksConnectionId,
                defaults: setupDefaults
            )
        }
    }

    func activate(workspace: WorkspaceRecord) {
        activationGeneration += 1
        errorMessage = nil
        apply(WorkspaceAISettingsSnapshot(workspace: workspace, localAccountSettings: localAccountSettings, defaults: setupDefaults))
        if let snapshot { saveAccountSettings(snapshot) }
        observeWorkspace()
        scheduleRuntimeActivation()
    }

    func clear() {
        activationGeneration += 1
        workspaceID = nil
        workspaceObservation?.cancel()
        workspaceObservation = nil
        isSwitchingRuntime = false
        errorMessage = nil
        runtimeTask?.cancel()
        runtimeTask = nil
    }

    func waitForRuntimeContext() async -> Bool {
        guard let runtimeTask else { return false }
        return await runtimeTask.value
    }

    private func observeWorkspace() {
        workspaceObservation?.cancel()
        guard let dbQueue, let workspaceID else { return }
        let generation = activationGeneration
        workspaceObservation = ValueObservation.tracking { db in
            try WorkspaceRecord.fetchOne(db, key: workspaceID)
        }.start(in: dbQueue, onError: { _ in }, onChange: { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Wait only for local saves, then read the latest row rather than an older observation.
                let savedGeneration = self.persistenceGeneration
                await self.saveTask?.value
                guard let workspace = try? await dbQueue.read({ db in
                    try WorkspaceRecord.fetchOne(db, key: workspaceID)
                }), self.activationGeneration == generation, self.persistenceGeneration == savedGeneration,
                self.workspaceID == workspaceID else { return }
                let changedAccount = self.accountConnectionID != workspace.accountConnectionId
                    || self.databricksAccountConnectionID != workspace.databricksConnectionId
                self.apply(WorkspaceAISettingsSnapshot(
                    workspace: workspace,
                    localAccountSettings: self.localAccountSettings,
                    defaults: self.setupDefaults
                ))
                if AppSettings.shared.currentWorkspace?.id == workspaceID {
                    AppSettings.shared.currentWorkspace = workspace
                }
                if changedAccount { self.scheduleRuntimeActivation() }
            }
        })
    }

    private func apply(_ settings: WorkspaceAISettingsSnapshot) {
        isApplying = true
        workspaceID = settings.workspaceID
        accountConnectionID = settings.accountConnectionID
        databricksAccountConnectionID = settings.databricksConnectionID
        generationSettings = settings.generationSettings
        chatModelID = settings.chatModelID
        chatReasoningEffort = settings.chatReasoningEffort
        isApplying = false
    }

    private func saveAccountSettings(_ snapshot: WorkspaceAISettingsSnapshot) {
        AccountInferenceSettings(snapshot: snapshot).save(
            connectionID: snapshot.accountConnectionID, databricksConnectionID: snapshot.databricksConnectionID, defaults: setupDefaults
        )
    }

    private func persistIfChanged<T: Equatable>(_ oldValue: T, _ newValue: T, persistsWorkspace: Bool = false) {
        guard oldValue != newValue, !isApplying, let snapshot else { return }
        saveAccountSettings(snapshot)
        guard persistsWorkspace, let dbQueue else { return }
        errorMessage = nil
        persistenceGeneration += 1
        let generation = activationGeneration
        let previousTask = saveTask
        saveTask = Task { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            do {
                let workspace = try await MeetingRepository(dbQueue: dbQueue).updateWorkspaceAISettings(snapshot)
                guard let self,
                      self.activationGeneration == generation,
                      self.workspaceID == snapshot.workspaceID,
                      let workspace
                else { return }
                if AppSettings.shared.currentWorkspace?.id == workspace.id {
                    AppSettings.shared.currentWorkspace = workspace
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.activationGeneration == generation,
                      self.workspaceID == snapshot.workspaceID
                else { return }
                self.errorMessage = error.localizedDescription
                if let workspace = try? await dbQueue.read({ db in
                    try WorkspaceRecord.fetchOne(db, key: snapshot.workspaceID)
                }) {
                    self.apply(WorkspaceAISettingsSnapshot(
                        workspace: workspace,
                        localAccountSettings: self.localAccountSettings,
                        defaults: self.setupDefaults
                    ))
                    self.scheduleRuntimeActivation(clearingError: false)
                }
            }
        }
    }

    private func persistLocalAccountSettingsIfChanged<T: Equatable>(_ oldValue: T, _ newValue: T) {
        guard oldValue != newValue, !isApplying else { return }
        localAccountSettings.save(to: setupDefaults)
        if workspaceID == nil, SetupTourPresentationPolicy.hasSavedProgress(in: setupDefaults) {
            SetupTourPresentationPolicy.saveProviderDraft(
                provider: localProvider,
                databricksProfile: databricksProfile,
                in: setupDefaults
            )
        }
        if isLocalAccount {
            scheduleRuntimeActivation()
        }
    }

    private func scheduleRuntimeActivationIfChanged<T: Equatable>(_ oldValue: T, _ newValue: T) {
        guard oldValue != newValue, !isApplying else { return }
        scheduleRuntimeActivation()
    }

    private func scheduleRuntimeActivation(clearingError: Bool = true) {
        guard let snapshot else { return }
        let generation = activationGeneration
        let activateRuntime = activateRuntime
        runtimeTask?.cancel()
        if clearingError { errorMessage = nil }
        isSwitchingRuntime = true
        runtimeTask = Task { [weak self] in
            do {
                try await activateRuntime(snapshot)
                guard let self,
                      self.activationGeneration == generation,
                      self.workspaceID == snapshot.workspaceID
                else { return false }
                self.isSwitchingRuntime = false
                return true
            } catch is CancellationError {
                guard !Task.isCancelled,
                      let self,
                      self.activationGeneration == generation,
                      self.workspaceID == snapshot.workspaceID
                else { return false }
                self.isSwitchingRuntime = false
                self.errorMessage = CodexConfigurationError.accountNotReady.localizedDescription
                return false
            } catch {
                guard let self,
                      self.activationGeneration == generation,
                      self.workspaceID == snapshot.workspaceID
                else { return false }
                self.isSwitchingRuntime = false
                self.errorMessage = error.localizedDescription
                return false
            }
        }
    }
}
