import DahliaRuntimeSupport
import Foundation
import Observation

@MainActor
@Observable
final class SetupTourModel {
    let mode: SetupTourMode
    let originalVault: VaultRecord?

    private(set) var currentStep: SetupTourStep
    private(set) var isVaultLocationConfirmed: Bool
    private(set) var isCompleting = false
    private(set) var errorMessage: String?
    private(set) var selectedVaultURL: URL
    private let progressDefaults: UserDefaults?

    nonisolated static func newVaultURL(named proposedName: String) -> URL? {
        guard let name = DahliaProjectName.normalizedName(proposedName) else { return nil }
        return URL.documentsDirectory.appending(path: name, directoryHint: .isDirectory)
    }

    init(
        mode: SetupTourMode,
        currentVault: VaultRecord?,
        progressDefaults: UserDefaults? = nil
    ) {
        self.mode = mode
        originalVault = currentVault
        self.progressDefaults = progressDefaults

        if mode == .initial, currentVault == nil, let progressDefaults {
            let restoredVaultURL = SetupTourPresentationPolicy.restoredVaultURL(in: progressDefaults)
            let restoredVaultConfirmed = restoredVaultURL != nil
                && SetupTourPresentationPolicy.isRestoredVaultConfirmed(in: progressDefaults)
            let restoredStep = SetupTourPresentationPolicy.restoredStep(in: progressDefaults)
            currentStep = restoredStep.rawValue > SetupTourStep.vault.rawValue && !restoredVaultConfirmed
                ? .vault
                : restoredStep
            selectedVaultURL = restoredVaultURL ?? VaultManagementModel.defaultVaultURL
            isVaultLocationConfirmed = restoredVaultConfirmed
        } else {
            currentStep = .vault
            selectedVaultURL = currentVault?.url ?? VaultManagementModel.defaultVaultURL
            isVaultLocationConfirmed = currentVault != nil
        }
    }

    var canGoBack: Bool {
        currentStep != .vault && !isCompleting
    }

    var canContinue: Bool {
        !isCompleting && (currentStep != .vault || isVaultLocationConfirmed)
    }

    func selectVaultURL(_ url: URL) {
        selectedVaultURL = url
        isVaultLocationConfirmed = originalVault?.url.standardizedFileURL == url.standardizedFileURL
        errorMessage = nil
        persistProgress()
    }

    func confirmVaultSelection() {
        isVaultLocationConfirmed = true
        errorMessage = nil
        persistProgress()
    }

    func advance() {
        guard canContinue,
              let next = SetupTourStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
        errorMessage = nil
        persistProgress()
    }

    func goBack() {
        guard canGoBack,
              let previous = SetupTourStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = previous
        errorMessage = nil
        persistProgress()
    }

    func beginCompletion() {
        isCompleting = true
        errorMessage = nil
    }

    func finishCompletion(errorMessage: String?) {
        isCompleting = false
        self.errorMessage = errorMessage
    }

    func returnToStep(_ step: SetupTourStep) {
        guard step.rawValue < currentStep.rawValue, !isCompleting else { return }
        currentStep = step
        errorMessage = nil
        persistProgress()
    }

    private func persistProgress() {
        guard mode == .initial, let progressDefaults else { return }
        SetupTourPresentationPolicy.saveProgress(
            step: currentStep,
            vaultURL: selectedVaultURL,
            isVaultConfirmed: isVaultLocationConfirmed,
            in: progressDefaults
        )
    }
}
