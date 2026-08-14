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
    private(set) var isShowingSettings = false
    private(set) var sidebarWidth: CGFloat
    var settingsCategory: SettingsCategory {
        didSet {
            SettingsNavigation.saveSelection(settingsCategory, in: settingsDefaults)
        }
    }

    var selectedProjectId: UUID?
    var projectSearchText = ""
    var expandedProjectIds: Set<UUID> = []

    private var projectVaultId: UUID?
    private var navigationGeneration = 0
    private var backHistory: [MainWindowLocation] = []
    private var forwardHistory: [MainWindowLocation] = []

    private let openMainWindow: @MainActor () -> Void
    private let openMainWindowWithoutActivation: @MainActor () -> Void
    private let settingsDefaults: UserDefaults

    init(
        openMainWindow: @escaping @MainActor () -> Void = { MainWindowOpener.shared.openMainWindow() },
        openMainWindowWithoutActivation: @escaping @MainActor () -> Void = {
            MainWindowOpener.shared.openMainWindowWithoutActivation()
        },
        initialSettingsCategory: SettingsCategory? = nil,
        settingsDefaults: UserDefaults = .standard
    ) {
        self.openMainWindow = openMainWindow
        self.openMainWindowWithoutActivation = openMainWindowWithoutActivation
        self.settingsDefaults = settingsDefaults
        let storedSidebarWidth = settingsDefaults.object(forKey: MainSidebarLayout.widthDefaultsKey) == nil
            ? MainSidebarLayout.defaultWidth
            : settingsDefaults.double(forKey: MainSidebarLayout.widthDefaultsKey)
        let clampedSidebarWidth = MainSidebarLayout.clampedWidth(storedSidebarWidth)
        sidebarWidth = clampedSidebarWidth
        if clampedSidebarWidth != storedSidebarWidth {
            settingsDefaults.set(clampedSidebarWidth, forKey: MainSidebarLayout.widthDefaultsKey)
        }
        settingsCategory = initialSettingsCategory.map(SettingsNavigation.visibleSelection)
            ?? SettingsNavigation.savedSelection(in: settingsDefaults)
    }

    func showMeetings() {
        section = .meetings
    }

    func showProjects() {
        section = .projects
    }

    func openProjects() {
        dismissSettings()
        recordNavigation(to: .project(selectedProjectId))
        showProjects()
        openMainWindow()
    }

    func openMeetings() {
        dismissSettings()
        showMeetings()
        openMainWindow()
    }

    func openMeetingsWithoutActivation() {
        dismissSettings()
        showMeetings()
        openMainWindowWithoutActivation()
    }

    func openSettings(category: SettingsCategory? = nil) {
        if let category {
            settingsCategory = SettingsNavigation.visibleSelection(category)
        }
        isShowingSettings = true
        openMainWindow()
    }

    func dismissSettings() {
        isShowingSettings = false
    }

    func updateSidebarWidth(_ width: CGFloat) {
        let clampedWidth = MainSidebarLayout.clampedWidth(width)
        guard clampedWidth != sidebarWidth else { return }
        sidebarWidth = clampedWidth
        settingsDefaults.set(clampedWidth, forKey: MainSidebarLayout.widthDefaultsKey)
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

    func recordUpcomingScheduleIfVisible(_ isVisible: Bool) {
        guard isVisible, section == .meetings,
              case .meeting = currentLocation else { return }
        recordNavigation(to: .upcomingSchedule)
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
            reconcileProjectHistory(with: projects)
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

    private func reconcileProjectHistory(with projects: [ProjectOverviewItem]) {
        if !projects.isEmpty {
            let availableProjectIds = Set(projects.map(\.projectId))
            backHistory.removeAll { $0.referencesUnavailableProject(in: availableProjectIds) }
            forwardHistory.removeAll { $0.referencesUnavailableProject(in: availableProjectIds) }
        }
        while backHistory.last == currentLocation {
            backHistory.removeLast()
        }
        while forwardHistory.last == currentLocation {
            forwardHistory.removeLast()
        }
    }
}

private extension MainWindowLocation {
    func referencesUnavailableProject(in availableProjectIds: Set<UUID>) -> Bool {
        guard case let .project(projectId?) = self else { return false }
        return !availableProjectIds.contains(projectId)
    }
}
