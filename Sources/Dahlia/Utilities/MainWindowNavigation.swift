import Foundation
import Observation

enum MainWindowLocation: Equatable {
    case upcomingSchedule
    case unprocessedRecordings
    case meeting(UUID)
    case meetingDraft(DraftMeeting, noteText: String)
    case projects
    case project(UUID)

    var section: MainWindowSection {
        switch self {
        case .upcomingSchedule, .unprocessedRecordings, .meeting, .meetingDraft:
            .meetings
        case .projects, .project:
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
    private static let projectDetailDisplayModesDefaultsKey = "projectDetailDisplayModes"

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

    var meetingSidebarDisplayMode: MeetingSidebarDisplayMode {
        didSet {
            settingsDefaults.set(meetingSidebarDisplayMode.rawValue, forKey: Self.meetingSidebarDisplayModeDefaultsKey)
        }
    }

    private var pinnedProjectIDsByVault: [String: [String]]
    private var projectAppearancesByVault: [String: [String: ProjectAppearance]]
    private var projectDetailDisplayModesByVault: [String: ProjectDetailDisplayMode]
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
        projectDetailDisplayModesByVault = Self.loadProjectDetailDisplayModes(from: settingsDefaults)
    }

    func showMeetings() {
        section = .meetings
    }

    func showProjects() {
        section = .projects
    }

    func openProjects() {
        dismissSettings()
        recordNavigation(to: .projects)
        openMainWindow()
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

    func projectDetailDisplayMode(vaultId: UUID?) -> ProjectDetailDisplayMode {
        guard let vaultId else { return .list }
        return projectDetailDisplayModesByVault[vaultId.uuidString] ?? .list
    }

    func setProjectDetailDisplayMode(_ mode: ProjectDetailDisplayMode, vaultId: UUID?) {
        guard let vaultId else { return }
        projectDetailDisplayModesByVault[vaultId.uuidString] = mode
        saveProjectDetailDisplayModes()
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

    private static func loadProjectDetailDisplayModes(from defaults: UserDefaults) -> [String: ProjectDetailDisplayMode] {
        guard let data = defaults.data(forKey: projectDetailDisplayModesDefaultsKey),
              let values = try? JSONDecoder().decode([String: ProjectDetailDisplayMode].self, from: data) else { return [:] }
        return values
    }

    private func saveProjectDetailDisplayModes() {
        guard let data = try? JSONEncoder().encode(projectDetailDisplayModesByVault) else { return }
        settingsDefaults.set(data, forKey: Self.projectDetailDisplayModesDefaultsKey)
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

    func updateDraftNavigation(_ draftMeeting: DraftMeeting, noteText: String) {
        guard case let .meetingDraft(currentDraft, _) = currentLocation,
              currentDraft.id == draftMeeting.id else { return }
        currentLocation = .meetingDraft(draftMeeting, noteText: noteText)
    }

    func replaceDraftNavigation(draftID: UUID, with meetingID: UUID) {
        let replacement = MainWindowLocation.meeting(meetingID)
        currentLocation = currentLocation.replacingDraft(id: draftID, with: replacement)
        backHistory = replacingDraft(id: draftID, with: replacement, in: backHistory)
        forwardHistory = replacingDraft(id: draftID, with: replacement, in: forwardHistory)
        if backHistory.last == currentLocation {
            backHistory.removeLast()
        }
        if forwardHistory.last == currentLocation {
            forwardHistory.removeLast()
        }
    }

    private func replacingDraft(
        id: UUID,
        with replacement: MainWindowLocation,
        in history: [MainWindowLocation]
    ) -> [MainWindowLocation] {
        history.reduce(into: []) { result, location in
            let location = location.replacingDraft(id: id, with: replacement)
            if result.last != location {
                result.append(location)
            }
        }
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

    func changeVault(to _: UUID?) {
        let location: MainWindowLocation = if section == .projects {
            .projects
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

private extension MainWindowLocation {
    func replacingDraft(id: UUID, with replacement: MainWindowLocation) -> MainWindowLocation {
        guard case let .meetingDraft(draftMeeting, _) = self,
              draftMeeting.id == id else { return self }
        return replacement
    }
}
