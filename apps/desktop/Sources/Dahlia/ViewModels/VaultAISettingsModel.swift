import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class VaultAISettingsModel {
    static let shared = VaultAISettingsModel()

    private(set) var vaultID: UUID?
    var accountConnectionID: UUID? {
        didSet {
            persistIfChanged(oldValue, accountConnectionID)
            scheduleRuntimeActivationIfChanged(oldValue, accountConnectionID)
        }
    }

    /// These two settings belong to the Local Account and survive vault activation.
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
    @ObservationIgnored private let activateRuntime: @Sendable (VaultAISettingsSnapshot) async throws -> Void

    init(
        setupDefaults: UserDefaults = .standard,
        activateRuntime: @escaping @Sendable (VaultAISettingsSnapshot) async throws -> Void = {
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

    var snapshot: VaultAISettingsSnapshot? {
        guard let vaultID else { return nil }
        return snapshot(for: vaultID)
    }

    func snapshot(for vaultID: UUID) -> VaultAISettingsSnapshot {
        VaultAISettingsSnapshot(
            vaultID: vaultID,
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

    func configure(dbQueue: DatabaseQueue) async throws {
        self.dbQueue = dbQueue
        guard !setupDefaults.bool(forKey: LocalAccountAISettings.migrationKey) else { return }
        let previousVault = try await MeetingRepository(dbQueue: dbQueue).fetchLatestLocalAccountVault()
        guard !setupDefaults.bool(forKey: LocalAccountAISettings.migrationKey) else { return }
        isApplying = true
        if let previousVault {
            localProvider = previousVault.localProvider
            databricksProfile = previousVault.databricksProfile
        }
        isApplying = false
        localAccountSettings.save(to: setupDefaults)
    }

    func activate(vault: VaultRecord) {
        activationGeneration += 1
        errorMessage = nil
        apply(VaultAISettingsSnapshot(vault: vault, localAccountSettings: localAccountSettings))
        scheduleRuntimeActivation()
    }

    func clear() {
        activationGeneration += 1
        vaultID = nil
        isSwitchingRuntime = false
        errorMessage = nil
        runtimeTask?.cancel()
        runtimeTask = nil
    }

    func waitForRuntimeContext() async -> Bool {
        guard let runtimeTask else { return false }
        return await runtimeTask.value
    }

    private func apply(_ settings: VaultAISettingsSnapshot) {
        isApplying = true
        vaultID = settings.vaultID
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
                let vault = try await MeetingRepository(dbQueue: dbQueue).updateVaultAISettings(snapshot)
                guard let self,
                      self.activationGeneration == generation,
                      self.vaultID == snapshot.vaultID,
                      let vault
                else { return }
                if AppSettings.shared.currentVault?.id == vault.id {
                    AppSettings.shared.currentVault = vault
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.activationGeneration == generation,
                      self.vaultID == snapshot.vaultID
                else { return }
                self.errorMessage = error.localizedDescription
                if let vault = try? await dbQueue.read({ db in
                    try VaultRecord.fetchOne(db, key: snapshot.vaultID)
                }) {
                    self.apply(VaultAISettingsSnapshot(vault: vault, localAccountSettings: self.localAccountSettings))
                    self.scheduleRuntimeActivation()
                }
            }
        }
    }

    private func persistLocalAccountSettingsIfChanged<T: Equatable>(_ oldValue: T, _ newValue: T) {
        guard oldValue != newValue, !isApplying else { return }
        localAccountSettings.save(to: setupDefaults)
        if vaultID == nil, SetupTourPresentationPolicy.hasSavedProgress(in: setupDefaults) {
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
                      self.vaultID == snapshot.vaultID
                else { return false }
                self.isSwitchingRuntime = false
                return true
            } catch is CancellationError {
                guard !Task.isCancelled,
                      let self,
                      self.activationGeneration == generation,
                      self.vaultID == snapshot.vaultID
                else { return false }
                self.isSwitchingRuntime = false
                self.errorMessage = CodexConfigurationError.accountNotReady.localizedDescription
                return false
            } catch {
                guard let self,
                      self.activationGeneration == generation,
                      self.vaultID == snapshot.vaultID
                else { return false }
                self.isSwitchingRuntime = false
                self.errorMessage = error.localizedDescription
                return false
            }
        }
    }
}
