import Foundation
import Observation

enum MainWindowLocation: Equatable {
    case upcomingSchedule
    case unprocessedRecordings
    case meeting(UUID)
    case project(UUID?)

    var section: MainWindowSection {
        switch self {
        case .upcomingSchedule, .unprocessedRecordings, .meeting:
            .meetings
        case .project:
            .projects
        }
    }
}

@MainActor
@Observable
final class MainWindowNavigation {
    private enum HistoryDirection {
        case backward
        case forward
    }

    static let shared = MainWindowNavigation()

    private static let historyLimit = 50

    private(set) var section: MainWindowSection = .meetings
    private(set) var currentLocation: MainWindowLocation = .upcomingSchedule
    private(set) var isNavigatingHistory = false
    private(set) var hasInitializedNavigationHistory = false
    var selectedProjectId: UUID?
    var projectSearchText = ""
    var expandedProjectIds: Set<UUID> = []

    private var projectVaultId: UUID?
    private var navigationGeneration = 0
    private var backHistory: [MainWindowLocation] = []
    private var forwardHistory: [MainWindowLocation] = []

    private let openMainWindow: @MainActor () -> Void
    private let openMainWindowWithoutActivation: @MainActor () -> Void

    init(
        openMainWindow: @escaping @MainActor () -> Void = { MainWindowOpener.shared.openMainWindow() },
        openMainWindowWithoutActivation: @escaping @MainActor () -> Void = {
            MainWindowOpener.shared.openMainWindowWithoutActivation()
        }
    ) {
        self.openMainWindow = openMainWindow
        self.openMainWindowWithoutActivation = openMainWindowWithoutActivation
    }

    func showMeetings() {
        section = .meetings
    }

    func showProjects() {
        section = .projects
    }

    func openProjects() {
        recordNavigation(to: .project(selectedProjectId))
        showProjects()
        openMainWindow()
    }

    func openMeetings() {
        showMeetings()
        openMainWindow()
    }

    func openMeetingsWithoutActivation() {
        showMeetings()
        openMainWindowWithoutActivation()
    }

    var canGoBack: Bool { !backHistory.isEmpty && !isNavigatingHistory }
    var canGoForward: Bool { !forwardHistory.isEmpty && !isNavigatingHistory }

    func recordNavigation(to location: MainWindowLocation) {
        hasInitializedNavigationHistory = true
        cancelHistoryNavigation()
        guard currentLocation != location else {
            section = location.section
            return
        }
        appendToHistory(&backHistory, location: currentLocation)
        currentLocation = location
        forwardHistory = []
        section = location.section
    }

    func resetNavigationHistory(to location: MainWindowLocation) {
        hasInitializedNavigationHistory = true
        navigationGeneration += 1
        isNavigatingHistory = false
        currentLocation = location
        backHistory = []
        forwardHistory = []
        section = location.section
    }

    func initializeNavigationHistoryIfNeeded(to location: MainWindowLocation) {
        guard !hasInitializedNavigationHistory else { return }
        resetNavigationHistory(to: location)
    }

    func changeVault(to vaultId: UUID?) {
        projectVaultId = vaultId
        selectedProjectId = nil
        projectSearchText = ""
        expandedProjectIds = []
        let location: MainWindowLocation = if section == .projects {
            .project(nil)
        } else if currentLocation == .unprocessedRecordings {
            .unprocessedRecordings
        } else {
            .upcomingSchedule
        }
        resetNavigationHistory(to: location)
    }

    func goBack(
        validatingWith validate: (MainWindowLocation) async -> Bool,
        restoringWith restore: (MainWindowLocation) -> Void
    ) async {
        guard canGoBack else { return }
        await navigate(.backward, validatingWith: validate, restoringWith: restore)
    }

    func goForward(
        validatingWith validate: (MainWindowLocation) async -> Bool,
        restoringWith restore: (MainWindowLocation) -> Void
    ) async {
        guard canGoForward else { return }
        await navigate(.forward, validatingWith: validate, restoringWith: restore)
    }

    func cancelHistoryNavigation() {
        guard isNavigatingHistory else { return }
        navigationGeneration += 1
        isNavigatingHistory = false
    }

    func reconcileProjectCatalog(
        vaultId: UUID?,
        projects: [ProjectOverviewItem]
    ) {
        if projectVaultId != vaultId {
            projectVaultId = vaultId
            selectedProjectId = nil
            projectSearchText = ""
            expandedProjectIds.removeAll()
        }
        let reconciledProjectId = ProjectManagementSelection.reconciled(
            selectedProjectId: selectedProjectId,
            projects: projects
        )
        selectedProjectId = reconciledProjectId
        if section == .projects {
            currentLocation = .project(reconciledProjectId)
        }
    }

    private func navigate(
        _ direction: HistoryDirection,
        validatingWith validate: (MainWindowLocation) async -> Bool,
        restoringWith restore: (MainWindowLocation) -> Void
    ) async {
        navigationGeneration += 1
        let generation = navigationGeneration
        isNavigatingHistory = true
        defer {
            if generation == navigationGeneration {
                isNavigatingHistory = false
            }
        }

        while let location = nextLocation(for: direction) {
            let canRestore = await validate(location)
            guard generation == navigationGeneration else { return }
            removeNextLocation(for: direction)
            if canRestore {
                switch direction {
                case .backward:
                    appendToHistory(&forwardHistory, location: currentLocation)
                case .forward:
                    appendToHistory(&backHistory, location: currentLocation)
                }
                currentLocation = location
                section = location.section
                restore(location)
                return
            }
        }
    }

    private func nextLocation(for direction: HistoryDirection) -> MainWindowLocation? {
        switch direction {
        case .backward:
            backHistory.last
        case .forward:
            forwardHistory.last
        }
    }

    private func removeNextLocation(for direction: HistoryDirection) {
        switch direction {
        case .backward:
            backHistory.removeLast()
        case .forward:
            forwardHistory.removeLast()
        }
    }

    private func appendToHistory(
        _ history: inout [MainWindowLocation],
        location: MainWindowLocation
    ) {
        if history.last != location {
            history.append(location)
        }
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }
}
