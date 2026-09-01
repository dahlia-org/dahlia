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
    private(set) var selectedAccountConnectionID: UUID?
    private(set) var isAccountSelectionConfirmed: Bool
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
        selectedAccountConnectionID = currentVault?.accountConnectionId
        isAccountSelectionConfirmed = currentVault != nil
        self.progressDefaults = progressDefaults

        if mode == .initial, currentVault == nil, let progressDefaults {
            let restoredVaultURL = SetupTourPresentationPolicy.restoredVaultURL(in: progressDefaults)
            let restoredVaultConfirmed = restoredVaultURL != nil
                && SetupTourPresentationPolicy.isRestoredVaultConfirmed(in: progressDefaults)
            let restoredStep = SetupTourPresentationPolicy.restoredStep(in: progressDefaults)
            currentStep = restoredStep != .account && restoredStep != .vault && !restoredVaultConfirmed
                ? .vault
                : restoredStep
            selectedAccountConnectionID = SetupTourPresentationPolicy.restoredAccountConnectionID(in: progressDefaults)
            isAccountSelectionConfirmed = SetupTourPresentationPolicy.isAccountSelectionConfirmed(in: progressDefaults)
            selectedVaultURL = restoredVaultURL ?? VaultManagementModel.defaultVaultURL
            isVaultLocationConfirmed = restoredVaultConfirmed
        } else {
            currentStep = .account
            selectedVaultURL = currentVault?.url ?? VaultManagementModel.defaultVaultURL
            isVaultLocationConfirmed = currentVault != nil
        }
    }

    var canGoBack: Bool {
        currentStep != .account && !isCompleting
    }

    var canContinue: Bool {
        !isCompleting
            && (currentStep != .account || isAccountSelectionConfirmed)
            && (currentStep != .vault || isVaultLocationConfirmed)
    }

    var visibleSteps: [SetupTourStep] {
        SetupTourStep.allCases.filter { selectedAccountConnectionID == nil || $0 != .modelProvider }
    }

    func selectAccountConnection(_ connectionID: UUID?) {
        selectedAccountConnectionID = connectionID
        isAccountSelectionConfirmed = true
        errorMessage = nil
        persistProgress()
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
              let currentIndex = visibleSteps.firstIndex(of: currentStep),
              visibleSteps.indices.contains(currentIndex + 1) else { return }
        currentStep = visibleSteps[currentIndex + 1]
        errorMessage = nil
        persistProgress()
    }

    func goBack() {
        guard canGoBack,
              let currentIndex = visibleSteps.firstIndex(of: currentStep),
              visibleSteps.indices.contains(currentIndex - 1) else { return }
        currentStep = visibleSteps[currentIndex - 1]
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
        guard let stepIndex = visibleSteps.firstIndex(of: step),
              let currentIndex = visibleSteps.firstIndex(of: currentStep),
              stepIndex < currentIndex,
              !isCompleting else { return }
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
            accountConnectionID: selectedAccountConnectionID,
            isAccountSelectionConfirmed: isAccountSelectionConfirmed,
            in: progressDefaults
        )
    }
}
