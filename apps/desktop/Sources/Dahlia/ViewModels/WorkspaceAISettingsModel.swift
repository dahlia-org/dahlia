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
            persistIfChanged(oldValue, accountConnectionID)
            scheduleRuntimeActivationIfChanged(oldValue, accountConnectionID)
        }
    }

    /// Mac-wide inference preferences survive activation of either local or Server Workspaces.
    var localProvider: AIAccountProvider {
        didSet { persistLocalAccountSettingsIfChanged(oldValue, localProvider) }
    }

    var databricksProfile: String {
        didSet { persistLocalAccountSettingsIfChanged(oldValue, databricksProfile) }
    }

    var summaryModelID: String { didSet { persistIfChanged(oldValue, summaryModelID) } }
    var summaryReasoningEffort: String { didSet { persistIfChanged(oldValue, summaryReasoningEffort) } }
    var chatModelID: String { didSet { persistIfChanged(oldValue, chatModelID) } }
    var chatReasoningEffort: String { didSet { persistIfChanged(oldValue, chatReasoningEffort) } }
    private(set) var isSwitchingRuntime = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var dbQueue: DatabaseQueue?
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var activationGeneration = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var runtimeTask: Task<Bool, Never>?
    @ObservationIgnored private let setupDefaults: UserDefaults
    @ObservationIgnored private let activateRuntime: @Sendable (WorkspaceAISettingsSnapshot) async throws -> Void

    init(
        setupDefaults: UserDefaults = .standard,
        activateRuntime: @escaping @Sendable (WorkspaceAISettingsSnapshot) async throws -> Void = {
            try await CodexRuntimeContextCoordinator.shared.activate($0)
        }
    ) {
        self.setupDefaults = setupDefaults
        self.activateRuntime = activateRuntime
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
        summaryModelID = "gpt-5.6-luna"
        summaryReasoningEffort = "high"
        chatModelID = ""
        chatReasoningEffort = CodexReasoningEffortOption.defaultValue
    }

    var snapshot: WorkspaceAISettingsSnapshot? {
        guard let workspaceID else { return nil }
        return snapshot(for: workspaceID)
    }

    func snapshot(for workspaceID: UUID) -> WorkspaceAISettingsSnapshot {
        WorkspaceAISettingsSnapshot(
            workspaceID: workspaceID,
            accountConnectionID: accountConnectionID,
            localProvider: localProvider,
            databricksProfile: databricksProfile,
            summaryModelID: summaryModelID,
            summaryReasoningEffort: summaryReasoningEffort,
            chatModelID: chatModelID,
            chatReasoningEffort: chatReasoningEffort
        )
    }

    var isLocalAccount: Bool { accountConnectionID == nil }

    var localAccountSettings: LocalAccountAISettings {
        LocalAccountAISettings(provider: localProvider, databricksProfile: databricksProfile)
    }

    func configure(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func inheritLocalAccountSettings(from dbQueue: DatabaseQueue) async throws {
        let migratesProvider = !setupDefaults.bool(forKey: LocalAccountAISettings.migrationKey)
        let migratesSummary = !setupDefaults.bool(forKey: LocalAccountAISettings.summaryMigrationKey)
        guard migratesProvider || migratesSummary else { return }
        let previousWorkspace = try await MeetingRepository(dbQueue: dbQueue).fetchLatestLocalAccountWorkspace()
        isApplying = true
        if migratesProvider, let previousWorkspace {
            localProvider = previousWorkspace.localProvider
            databricksProfile = previousWorkspace.databricksProfile
        }
        isApplying = false
        if migratesProvider { localAccountSettings.save(to: setupDefaults) }
        if migratesSummary {
            if let previousWorkspace {
                setupDefaults.set(previousWorkspace.summaryModelID, forKey: LocalAccountAISettings.summaryModelKey)
                setupDefaults.set(previousWorkspace.summaryReasoningEffort, forKey: LocalAccountAISettings.summaryReasoningEffortKey)
            }
            setupDefaults.set(true, forKey: LocalAccountAISettings.summaryMigrationKey)
        }
    }

    func activate(workspace: WorkspaceRecord) {
        activationGeneration += 1
        errorMessage = nil
        apply(WorkspaceAISettingsSnapshot(workspace: workspace, localAccountSettings: localAccountSettings))
        scheduleRuntimeActivation()
    }

    func clear() {
        activationGeneration += 1
        workspaceID = nil
        isSwitchingRuntime = false
        errorMessage = nil
        runtimeTask?.cancel()
        runtimeTask = nil
    }

    func waitForRuntimeContext() async -> Bool {
        guard let runtimeTask else { return false }
        return await runtimeTask.value
    }

    private func apply(_ settings: WorkspaceAISettingsSnapshot) {
        isApplying = true
        workspaceID = settings.workspaceID
        accountConnectionID = settings.accountConnectionID
        summaryModelID = settings.summaryModelID
        summaryReasoningEffort = settings.summaryReasoningEffort
        chatModelID = settings.chatModelID
        chatReasoningEffort = settings.chatReasoningEffort
        isApplying = false
    }

    private func persistIfChanged<T: Equatable>(_ oldValue: T, _ newValue: T) {
        guard oldValue != newValue, !isApplying, let snapshot, let dbQueue else { return }
        errorMessage = nil
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
                    self.apply(WorkspaceAISettingsSnapshot(workspace: workspace, localAccountSettings: self.localAccountSettings))
                    self.scheduleRuntimeActivation()
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

    private func scheduleRuntimeActivation() {
        guard let snapshot else { return }
        let generation = activationGeneration
        let activateRuntime = activateRuntime
        runtimeTask?.cancel()
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
