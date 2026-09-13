import DahliaRuntimeSupport
import Foundation
import Observation

@MainActor
@Observable
final class SetupTourModel {
    let mode: SetupTourMode
    let originalWorkspace: WorkspaceRecord?

    private(set) var currentStep: SetupTourStep
    private(set) var isWorkspaceLocationConfirmed: Bool
    private(set) var isCompleting = false
    private(set) var errorMessage: String?
    private(set) var selectedWorkspaceURL: URL
    private(set) var selectedWorkspaceName: String?
    private(set) var selectedExistingWorkspaceID: UUID?
    private(set) var didSelectWorkspaceLocation = false
    private(set) var selectedAccountConnectionID: UUID?
    private(set) var isAccountSelectionConfirmed: Bool
    private let progressDefaults: UserDefaults?

    init(
        mode: SetupTourMode,
        currentWorkspace: WorkspaceRecord?,
        signedInAccountConnectionIDs: Set<UUID> = [],
        progressDefaults: UserDefaults? = nil
    ) {
        self.mode = mode
        originalWorkspace = currentWorkspace
        selectedAccountConnectionID = currentWorkspace?.accountConnectionId
        isAccountSelectionConfirmed = currentWorkspace.map { workspace in
            guard let connectionID = workspace.accountConnectionId else { return true }
            return signedInAccountConnectionIDs.contains(connectionID)
        } ?? false
        self.progressDefaults = progressDefaults

        if mode == .initial, currentWorkspace == nil, let progressDefaults {
            let restoredWorkspaceURL = SetupTourPresentationPolicy.restoredWorkspaceURL(in: progressDefaults)
            let restoredWorkspaceConfirmed = restoredWorkspaceURL != nil
                && SetupTourPresentationPolicy.isRestoredWorkspaceConfirmed(in: progressDefaults)
            let restoredStep = SetupTourPresentationPolicy.restoredStep(in: progressDefaults)
            let restoredConnectionID = SetupTourPresentationPolicy.restoredAccountConnectionID(in: progressDefaults)
            let restoredAccountConfirmed = SetupTourPresentationPolicy.isAccountSelectionConfirmed(in: progressDefaults)
                && (restoredConnectionID.map(signedInAccountConnectionIDs.contains) ?? true)
            currentStep = if !restoredAccountConfirmed {
                .account
            } else if restoredStep != .account,
                      restoredStep != .workspace,
                      !restoredWorkspaceConfirmed {
                .workspace
            } else {
                restoredStep
            }
            selectedAccountConnectionID = restoredConnectionID
            isAccountSelectionConfirmed = restoredAccountConfirmed
            selectedWorkspaceURL = restoredWorkspaceURL ?? WorkspaceManagementModel.defaultWorkspaceURL
            selectedWorkspaceName = SetupTourPresentationPolicy.restoredWorkspaceName(in: progressDefaults)
            isWorkspaceLocationConfirmed = restoredWorkspaceConfirmed
        } else {
            currentStep = .account
            selectedWorkspaceURL = currentWorkspace?.url ?? WorkspaceManagementModel.defaultWorkspaceURL
            selectedWorkspaceName = nil
            isWorkspaceLocationConfirmed = currentWorkspace != nil
        }
    }

    var canGoBack: Bool {
        currentStep != .account && !isCompleting
    }

    var canContinue: Bool {
        !isCompleting
            && (currentStep != .account || isAccountSelectionConfirmed)
            && (currentStep != .workspace || isWorkspaceLocationConfirmed)
    }

    var visibleSteps: [SetupTourStep] {
        SetupTourStep.allCases.filter { selectedAccountConnectionID == nil || $0 != .modelProvider }
    }

    func selectAccountConnection(_ connectionID: UUID?) {
        if connectionID != selectedAccountConnectionID, selectedExistingWorkspaceID != nil {
            selectedExistingWorkspaceID = nil
            isWorkspaceLocationConfirmed = false
        }
        selectedAccountConnectionID = connectionID
        isAccountSelectionConfirmed = true
        errorMessage = nil
        persistProgress()
    }

    func selectWorkspaceURL(_ url: URL) {
        selectedExistingWorkspaceID = nil
        selectedWorkspaceURL = url
        selectedWorkspaceName = nil
        didSelectWorkspaceLocation = true
        isWorkspaceLocationConfirmed = originalWorkspace?.url?.standardizedFileURL == url.standardizedFileURL
        errorMessage = nil
        persistProgress()
    }

    func selectPathlessWorkspace(named name: String) {
        guard let name = DahliaProjectName.normalizedName(name) else { return }
        selectedExistingWorkspaceID = nil
        selectedWorkspaceName = name
        selectedWorkspaceURL = WorkspaceManagementModel.defaultWorkspaceURL
        didSelectWorkspaceLocation = true
        isWorkspaceLocationConfirmed = true
        errorMessage = nil
        persistProgress()
    }

    func selectExistingWorkspace(_ workspace: WorkspaceRecord) {
        guard workspace.accountConnectionId == selectedAccountConnectionID else { return }
        selectedExistingWorkspaceID = workspace.id
        selectedWorkspaceName = nil
        didSelectWorkspaceLocation = true
        isWorkspaceLocationConfirmed = true
        errorMessage = nil
        persistProgress()
    }

    func confirmWorkspaceSelection() {
        isWorkspaceLocationConfirmed = true
        errorMessage = nil
        persistProgress()
    }

    var keepsOriginalWorkspace: Bool {
        guard let originalWorkspace else { return false }
        if let selectedExistingWorkspaceID { return selectedExistingWorkspaceID == originalWorkspace.id }
        return selectedWorkspaceName == nil && (!didSelectWorkspaceLocation
            || originalWorkspace.url?.standardizedFileURL == selectedWorkspaceURL.standardizedFileURL
        )
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
            workspaceURL: selectedWorkspaceURL,
            workspaceName: selectedWorkspaceName,
            // Revalidate an automatically discovered selection after relaunch.
            isWorkspaceConfirmed: isWorkspaceLocationConfirmed && selectedExistingWorkspaceID == nil,
            accountConnectionID: selectedAccountConnectionID,
            isAccountSelectionConfirmed: isAccountSelectionConfirmed,
            in: progressDefaults
        )
    }
}
