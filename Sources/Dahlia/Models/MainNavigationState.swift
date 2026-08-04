import Foundation

enum MainNavigationRoute: Hashable {
    case schedule
    case meetings
    case project(UUID)
    case organizations

    var projectID: UUID? {
        guard case let .project(id) = self else { return nil }
        return id
    }

    var showsMeetingList: Bool {
        switch self {
        case .meetings, .project: true
        case .schedule, .organizations: false
        }
    }
}

struct MainNavigationState: Equatable {
    private struct Location: Equatable {
        let route: MainNavigationRoute
        let meetingSelection: Set<UUID>
    }

    private(set) var route: MainNavigationRoute
    private(set) var meetingSelection: Set<UUID>
    private var backHistory: [Location] = []
    private var forwardHistory: [Location] = []

    init(
        route: MainNavigationRoute = .meetings,
        meetingSelection: Set<UUID> = []
    ) {
        self.route = route
        self.meetingSelection = route.showsMeetingList ? meetingSelection : []
    }

    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }

    mutating func select(_ route: MainNavigationRoute) {
        navigate(to: Location(
            route: route,
            meetingSelection: route.showsMeetingList ? meetingSelection : []
        ))
    }

    mutating func selectMeetings(_ selection: Set<UUID>) {
        navigate(to: Location(
            route: !selection.isEmpty && !route.showsMeetingList ? .meetings : route,
            meetingSelection: selection
        ))
    }

    mutating func reconcileSelectedMeetingProject(_ projectID: UUID?) {
        guard let scopeProjectID = route.projectID, scopeProjectID != projectID else { return }
        route = .meetings
    }

    mutating func reconcileOrganizationsAvailability(_ isAvailable: Bool) {
        guard !isAvailable else { return }
        backHistory.removeAll { $0.route == .organizations }
        forwardHistory.removeAll { $0.route == .organizations }
        guard route == .organizations else { return }
        route = .meetings
        meetingSelection.removeAll()
    }

    mutating func resetForVaultChange() {
        self = Self()
    }

    @discardableResult
    mutating func goBack() -> Bool {
        guard let location = backHistory.popLast() else { return false }
        forwardHistory.append(currentLocation)
        restore(location)
        return true
    }

    @discardableResult
    mutating func goForward() -> Bool {
        guard let location = forwardHistory.popLast() else { return false }
        backHistory.append(currentLocation)
        restore(location)
        return true
    }

    private var currentLocation: Location {
        Location(route: route, meetingSelection: meetingSelection)
    }

    private mutating func navigate(to location: Location) {
        guard location != currentLocation else { return }
        backHistory.append(currentLocation)
        forwardHistory.removeAll()
        restore(location)
    }

    private mutating func restore(_ location: Location) {
        route = location.route
        meetingSelection = location.meetingSelection
    }
}
