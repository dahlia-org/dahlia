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
    private static let meetingSidebarDisplayModeDefaultsKey = "meetingSidebarDisplayMode"
    private static let pinnedProjectIDsDefaultsKey = "meetingSidebarPinnedProjectIDs"
    private static let projectAppearancesDefaultsKey = "projectAppearances"

    private(set) var section: MainWindowSection = .meetings
    private(set) var currentLocation: MainWindowLocation = .upcomingSchedule
    private(set) var isNavigatingHistory = false
    private(set) var hasInitializedNavigationHistory = false
    private(set) var isShowingSettings = false
    private(set) var sidebarWidth: CGFloat
    private(set) var chatSidebarWidth: CGFloat
    var settingsCategory: SettingsCategory {
        didSet {
            SettingsNavigation.saveSelection(settingsCategory, in: settingsDefaults)
        }
    }

    var selectedProjectId: UUID? {
        didSet {
            if selectedProjectId != pendingCreatedProjectId {
                pendingCreatedProjectId = nil
            }
        }
    }

    var expandedProjectIds: Set<UUID> = []
    var meetingSidebarDisplayMode: MeetingSidebarDisplayMode {
        didSet {
            settingsDefaults.set(meetingSidebarDisplayMode.rawValue, forKey: Self.meetingSidebarDisplayModeDefaultsKey)
        }
    }

    private(set) var pendingProjectNavigationIntent: PendingProjectNavigationIntent?

    private var pinnedProjectIDsByVault: [String: [String]]
    private var projectAppearancesByVault: [String: [String: ProjectAppearance]]
    private var projectRevisionObservationTracker = ProjectRevisionObservationTracker()

    private var projectVaultId: UUID?
    private var pendingCreatedProjectId: UUID?
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
        let storedChatSidebarWidth = settingsDefaults.object(forKey: MainChatSidebarLayout.widthDefaultsKey) == nil
            ? MainChatSidebarLayout.defaultWidth
            : settingsDefaults.double(forKey: MainChatSidebarLayout.widthDefaultsKey)
        let clampedChatSidebarWidth = MainChatSidebarLayout.clampedWidth(storedChatSidebarWidth)
        chatSidebarWidth = clampedChatSidebarWidth
        if clampedChatSidebarWidth != storedChatSidebarWidth {
            settingsDefaults.set(clampedChatSidebarWidth, forKey: MainChatSidebarLayout.widthDefaultsKey)
        }
        settingsCategory = initialSettingsCategory.map(SettingsNavigation.visibleSelection)
            ?? SettingsNavigation.savedSelection(in: settingsDefaults)
        meetingSidebarDisplayMode = settingsDefaults.string(forKey: Self.meetingSidebarDisplayModeDefaultsKey)
            .flatMap(MeetingSidebarDisplayMode.init(rawValue:)) ?? .chronological
        pinnedProjectIDsByVault = Self.loadPinnedProjectIDs(from: settingsDefaults)
        projectAppearancesByVault = Self.loadProjectAppearances(from: settingsDefaults)
    }

    func showMeetings() {
        section = .meetings
    }

    func showProjects() {
        section = .projects
    }

    func selectCreatedProject(_ projectId: UUID) {
        pendingCreatedProjectId = projectId
        selectedProjectId = projectId
    }

    func openProjects() {
        dismissSettings()
        recordNavigation(to: .project(selectedProjectId))
        showProjects()
        openMainWindow()
    }

    func openProject(_ projectId: UUID, intent: ProjectNavigationIntent = .open) {
        selectedProjectId = projectId
        pendingProjectNavigationIntent = intent == .open
            ? nil
            : PendingProjectNavigationIntent(projectId: projectId, intent: intent)
        recordNavigation(to: .project(projectId))
        showProjects()
    }

    func consumeProjectNavigationIntent(for projectId: UUID) -> ProjectNavigationIntent? {
        guard pendingProjectNavigationIntent?.projectId == projectId else { return nil }
        defer { pendingProjectNavigationIntent = nil }
        return pendingProjectNavigationIntent?.intent
    }

    func pinnedProjectIDs(vaultId: UUID?) -> [UUID] {
        guard let vaultId else { return [] }
        return pinnedProjectIDsByVault[vaultId.uuidString, default: []].compactMap(UUID.init(uuidString:))
    }

    func toggleProjectPin(_ projectId: UUID, vaultId: UUID?) {
        guard let vaultId else { return }
        let vaultKey = vaultId.uuidString
        var ids = pinnedProjectIDsByVault[vaultKey, default: []]
        let id = projectId.uuidString
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.insert(id, at: 0)
        }
        pinnedProjectIDsByVault[vaultKey] = ids
        savePinnedProjectIDs()
    }

    func projectAppearance(projectId: UUID, vaultId: UUID?) -> ProjectAppearance {
        guard let vaultId else { return .default }
        return projectAppearancesByVault[vaultId.uuidString]?[projectId.uuidString] ?? .default
    }

    func setProjectAppearance(_ appearance: ProjectAppearance, projectId: UUID, vaultId: UUID?) {
        guard let vaultId else { return }
        projectAppearancesByVault[vaultId.uuidString, default: [:]][projectId.uuidString] = appearance
        saveProjectAppearances()
    }

    func recordLocalProjectRevision(projectId: UUID, revision: Int) {
        projectRevisionObservationTracker.record(projectId: projectId, revision: revision)
    }

    func consumeLocalProjectRevision(projectId: UUID, revision: Int) -> Bool {
        projectRevisionObservationTracker.consume(projectId: projectId, revision: revision)
    }

    func discardLocalProjectRevisions(projectId: UUID) {
        projectRevisionObservationTracker.discard(projectId: projectId)
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

    func updateChatSidebarWidth(_ width: CGFloat) {
        let clampedWidth = MainChatSidebarLayout.clampedWidth(width)
        guard clampedWidth != chatSidebarWidth else { return }
        chatSidebarWidth = clampedWidth
        settingsDefaults.set(clampedWidth, forKey: MainChatSidebarLayout.widthDefaultsKey)
    }

    private static func loadPinnedProjectIDs(from defaults: UserDefaults) -> [String: [String]] {
        guard let data = defaults.data(forKey: pinnedProjectIDsDefaultsKey),
              let values = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return values
    }

    private func savePinnedProjectIDs() {
        guard let data = try? JSONEncoder().encode(pinnedProjectIDsByVault) else { return }
        settingsDefaults.set(data, forKey: Self.pinnedProjectIDsDefaultsKey)
    }

    private static func loadProjectAppearances(from defaults: UserDefaults) -> [String: [String: ProjectAppearance]] {
        guard let data = defaults.data(forKey: projectAppearancesDefaultsKey),
              let values = try? JSONDecoder().decode([String: [String: ProjectAppearance]].self, from: data) else { return [:] }
        return values
    }

    private func saveProjectAppearances() {
        guard let data = try? JSONEncoder().encode(projectAppearancesByVault) else { return }
        settingsDefaults.set(data, forKey: Self.projectAppearancesDefaultsKey)
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
        pendingCreatedProjectId = nil
        selectedProjectId = nil
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
            pendingCreatedProjectId = nil
            selectedProjectId = nil
            expandedProjectIds.removeAll()
        }
        if let pendingCreatedProjectId,
           selectedProjectId == pendingCreatedProjectId,
           !projects.contains(where: { $0.projectId == pendingCreatedProjectId }) {
            return
        }
        pendingCreatedProjectId = nil
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
