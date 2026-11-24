import Foundation
import Observation

@MainActor
@Observable
final class SetupTourModel {
    let mode: SetupTourMode
    let originalWorkspace: WorkspaceRecord?

    private(set) var currentStep: SetupTourStep
    private(set) var isCompleting = false
    /// A tour that starts from the beginning checks for Pi before showing provider sign-in, which needs Pi itself.
    private(set) var isCheckingPi: Bool
    private(set) var needsPiSetup = false
    private(set) var errorMessage: String?
    private let progressDefaults: UserDefaults?
    private(set) var isPreparingWorkspace = false
    @ObservationIgnored private var preparationTask: Task<WorkspaceRecord?, Never>?
    private var preparationGeneration = 0

    init(
        mode: SetupTourMode,
        currentWorkspace: WorkspaceRecord?,
        progressDefaults: UserDefaults? = nil
    ) {
        self.mode = mode
        originalWorkspace = currentWorkspace
        self.progressDefaults = progressDefaults
        currentStep = .modelProvider
        isCheckingPi = true

        if mode == .initial, currentWorkspace == nil, let progressDefaults,
           let restoredStep = SetupTourPresentationPolicy.restoredStep(in: progressDefaults) {
            isCheckingPi = false
            needsPiSetup = restoredStep == .pi
            // An earlier release asked for model providers later, so its unfinished tour has not reached them yet.
            let skippedModelProvider = SetupTourPresentationPolicy.hasProgressBeforeModelProviderMoved(in: progressDefaults)
                && [.workingLanguages, .permissions].contains(restoredStep)
            currentStep = skippedModelProvider ? .modelProvider : restoredStep
        }
    }

    var canGoBack: Bool {
        currentStep != visibleSteps.first && !isCompleting && !isCheckingPi
    }

    var canContinue: Bool {
        !isCompleting && !isCheckingPi
    }

    var canDismiss: Bool {
        mode == .manual && !isCompleting
    }

    var visibleSteps: [SetupTourStep] {
        SetupTourStep.allCases.filter { $0 != .pi || needsPiSetup }
    }

    /// Offers Pi's installation first when it is missing. A cancelled check runs again when the tour reappears.
    func checkPi(
        isPiAvailable: () async -> Bool = {
            await Task.detached { (try? PiBundle.executableURL()) != nil }.value
        }
    ) async {
        guard isCheckingPi else { return }
        let available = await isPiAvailable()
        guard !Task.isCancelled else { return }
        isCheckingPi = false
        needsPiSetup = !available
        // Nothing can move the tour while it checks, so it is still at its first step.
        if needsPiSetup {
            currentStep = .pi
            persistProgress()
        }
    }

    func prepareInitialWorkspace(
        resolve: @escaping @MainActor () async -> WorkspaceRecord?
    ) async -> WorkspaceRecord? {
        guard mode == .initial else { return nil }
        // Creating Default must not make an unfinished tour disappear on the next launch.
        persistProgress()
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
        return workspace
    }

    var keepsOriginalWorkspace: Bool {
        originalWorkspace != nil
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
        SetupTourPresentationPolicy.saveProgress(step: currentStep, in: progressDefaults)
    }
}
