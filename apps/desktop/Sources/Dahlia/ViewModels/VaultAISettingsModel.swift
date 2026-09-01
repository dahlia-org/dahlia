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

    var localProvider: AIAccountProvider {
        didSet {
            persistSetupProviderDraftIfChanged(oldValue, localProvider)
            persistIfChanged(oldValue, localProvider)
            scheduleRuntimeActivationIfChanged(oldValue, localProvider)
        }
    }

    var databricksProfile: String {
        didSet {
            persistSetupProviderDraftIfChanged(oldValue, databricksProfile)
            persistIfChanged(oldValue, databricksProfile)
            scheduleRuntimeActivationIfChanged(oldValue, databricksProfile)
        }
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

    init(setupDefaults: UserDefaults = .standard) {
        self.setupDefaults = setupDefaults
        accountConnectionID = nil
        localProvider = SetupTourPresentationPolicy.restoredProvider(in: setupDefaults) ?? .chatGPTSubscription
        databricksProfile = SetupTourPresentationPolicy.restoredDatabricksProfile(in: setupDefaults)
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

    func configure(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func activate(vault: VaultRecord) {
        activationGeneration += 1
        errorMessage = nil
        apply(VaultAISettingsSnapshot(vault: vault))
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
        localProvider = settings.localProvider
        databricksProfile = settings.databricksProfile
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
                    self.apply(VaultAISettingsSnapshot(vault: vault))
                    self.scheduleRuntimeActivation()
                }
            }
        }
    }

    private func persistSetupProviderDraftIfChanged<T: Equatable>(_ oldValue: T, _ newValue: T) {
        guard vaultID == nil,
              oldValue != newValue,
              SetupTourPresentationPolicy.hasSavedProgress(in: setupDefaults)
        else { return }
        SetupTourPresentationPolicy.saveProviderDraft(
            provider: localProvider,
            databricksProfile: databricksProfile,
            in: setupDefaults
        )
    }

    private func scheduleRuntimeActivationIfChanged<T: Equatable>(_ oldValue: T, _ newValue: T) {
        guard oldValue != newValue, !isApplying else { return }
        scheduleRuntimeActivation()
    }

    private func scheduleRuntimeActivation() {
        guard let snapshot else { return }
        let generation = activationGeneration
        runtimeTask?.cancel()
        isSwitchingRuntime = true
        runtimeTask = Task { [weak self] in
            do {
                try await CodexRuntimeContextCoordinator.shared.activate(snapshot)
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
