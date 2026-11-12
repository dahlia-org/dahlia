import Foundation
import Observation

@MainActor
@Observable
final class SetupTourModel {
    let mode: SetupTourMode
    let originalWorkspace: WorkspaceRecord?

    private(set) var currentStep: SetupTourStep
    private(set) var isCompleting = false
    private(set) var isCheckingPi = false
    private(set) var needsPiSetup = false
    private(set) var errorMessage: String?
    private(set) var selectedAccountConnectionID: UUID?
    /// The Databricks account: local data listed under the connected Databricks workspace.
    private(set) var selectedDatabricksConnectionID: UUID?
    private(set) var isAccountSelectionConfirmed: Bool
    private let progressDefaults: UserDefaults?
    private(set) var isPreparingWorkspace = false
    @ObservationIgnored private var preparationTask: Task<WorkspaceRecord?, Never>?
    private var preparationGeneration = 0
    private var accountSelectionGeneration = 0

    init(
        mode: SetupTourMode,
        currentWorkspace: WorkspaceRecord?,
        signedInAccountConnectionIDs: Set<UUID> = [],
        progressDefaults: UserDefaults? = nil
    ) {
        self.mode = mode
        originalWorkspace = currentWorkspace
        selectedAccountConnectionID = currentWorkspace?.accountConnectionId
        selectedDatabricksConnectionID = currentWorkspace?.databricksConnectionId
        isAccountSelectionConfirmed = currentWorkspace.map { workspace in
            guard let connectionID = workspace.accountConnectionId else { return true }
            return signedInAccountConnectionIDs.contains(connectionID)
        } ?? false
        self.progressDefaults = progressDefaults
        currentStep = .account

        if mode == .initial, currentWorkspace == nil, let progressDefaults {
            let restoredStep = SetupTourPresentationPolicy.restoredStep(in: progressDefaults)
            needsPiSetup = restoredStep == .pi
            let restoredConnectionID = SetupTourPresentationPolicy.restoredAccountConnectionID(in: progressDefaults)
            let restoredAccountConfirmed = SetupTourPresentationPolicy.isAccountSelectionConfirmed(in: progressDefaults)
                // Databricks connections load after launch; one removed mid-tour fails at completion instead.
                && (restoredConnectionID.map(signedInAccountConnectionIDs.contains) ?? true)
            selectedAccountConnectionID = restoredConnectionID
            selectedDatabricksConnectionID = restoredConnectionID == nil
                ? SetupTourPresentationPolicy.restoredDatabricksConnectionID(in: progressDefaults)
                : nil
            isAccountSelectionConfirmed = restoredAccountConfirmed
            if restoredAccountConfirmed {
                // An earlier release asked for model providers later, so its unfinished tour has not reached them yet.
                let skippedModelProvider = SetupTourPresentationPolicy.hasProgressBeforeModelProviderMoved(in: progressDefaults)
                    && [.workingLanguages, .permissions].contains(restoredStep)
                    && visibleSteps.contains(.modelProvider)
                currentStep = if skippedModelProvider {
                    .modelProvider
                } else if visibleSteps.contains(restoredStep) {
                    restoredStep
                } else {
                    .workingLanguages
                }
            }
        }
    }

    var canGoBack: Bool {
        currentStep != .account && !isCompleting && !isCheckingPi
    }

    var canContinue: Bool {
        !isCompleting && !isCheckingPi && (currentStep != .account || isAccountSelectionConfirmed)
    }

    var visibleSteps: [SetupTourStep] {
        SetupTourStep.allCases.filter {
            if $0 == .pi { return needsPiSetup }
            // A Dahlia or Databricks account signs in during account selection and uses only its own models.
            return (selectedAccountConnectionID == nil && selectedDatabricksConnectionID == nil) || $0 != .modelProvider
        }
    }

    /// Resolve the selected account's Pi before opening provider sign-in, which needs Pi itself.
    func advanceFromAccount(
        isPiAvailable: (CodexRuntimeProvider) async -> Bool = { account in
            await Task.detached { (try? PiBundle.executableURL(for: account)) != nil }.value
        }
    ) async {
        guard currentStep == .account, canContinue else { return }
        let account = CodexRuntimeProvider(
            accountConnectionID: selectedAccountConnectionID,
            databricksConnectionID: selectedDatabricksConnectionID
        )
        let generation = accountSelectionGeneration
        isCheckingPi = true
        let available = await isPiAvailable(account)
        isCheckingPi = false
        guard !Task.isCancelled, generation == accountSelectionGeneration else { return }
        needsPiSetup = !available
        advance()
    }

    /// `databricks` chooses a connected Databricks workspace's account instead of the Local Account.
    func selectAccountConnection(_ connectionID: UUID?, databricks: UUID? = nil) {
        if connectionID != selectedAccountConnectionID || databricks != selectedDatabricksConnectionID {
            accountSelectionGeneration += 1
            preparationGeneration += 1
            preparationTask?.cancel()
            preparationTask = nil
            isPreparingWorkspace = false
        }
        selectedAccountConnectionID = connectionID
        selectedDatabricksConnectionID = connectionID == nil ? databricks : nil
        isAccountSelectionConfirmed = true
        errorMessage = nil
        persistProgress()
    }

    func prepareInitialWorkspace(
        resolve: @escaping @MainActor () async -> WorkspaceRecord?
    ) async -> WorkspaceRecord? {
        guard mode == .initial, isAccountSelectionConfirmed else { return nil }
        let task: Task<WorkspaceRecord?, Never>
        if let preparationTask {
            task = preparationTask
        } else {
            preparationGeneration += 1
            task = Task { await resolve() }
            preparationTask = task
            isPreparingWorkspace = true
        }
        let generation = preparationGeneration
        let workspace = await task.value
        guard generation == preparationGeneration else { return nil }
        preparationTask = nil
        isPreparingWorkspace = false
        guard let workspace, belongsToSelectedAccount(workspace) else { return nil }
        return workspace
    }

    func belongsToSelectedAccount(_ workspace: WorkspaceRecord) -> Bool {
        workspace.accountConnectionId == selectedAccountConnectionID
            && workspace.databricksConnectionId == selectedDatabricksConnectionID
    }

    /// Choosing another account in the tour opens that account's workspace instead.
    var keepsOriginalWorkspace: Bool {
        originalWorkspace.map(belongsToSelectedAccount) ?? false
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
            accountConnectionID: selectedAccountConnectionID,
            databricksConnectionID: selectedDatabricksConnectionID,
            isAccountSelectionConfirmed: isAccountSelectionConfirmed,
            in: progressDefaults
        )
    }
}
